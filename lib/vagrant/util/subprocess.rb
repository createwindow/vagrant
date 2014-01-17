require 'thread'

require 'childprocess'
require 'log4r'

require 'vagrant/util/io'
require 'vagrant/util/platform'
require 'vagrant/util/safe_chdir'
require 'vagrant/util/which'

module Vagrant
  module Util
    # Execute a command in a subprocess, gathering the results and
    # exit status.
    #
    # This class also allows you to read the data as it is outputted
    # from the subprocess in real time, by simply passing a block to
    # the execute method.
    class Subprocess
      # Convenience method for executing a method.
      def self.execute(*command, &block)
        new(*command).execute(&block)
      end

      def initialize(*command)
        @options = command.last.is_a?(Hash) ? command.pop : {}
        @command = command.dup
        @command[0] = Which.which(@command[0]) if !File.file?(@command[0])
        if !@command[0]
          raise Errors::CommandUnavailableWindows, file: command[0] if Platform.windows?
          raise Errors::CommandUnavailable, file: command[0]
        end

        @logger  = Log4r::Logger.new("vagrant::util::subprocess")
      end

      def execute
        # Get the timeout, if we have one
        timeout = @options[:timeout]

        # Get the working directory
        workdir = @options[:workdir] || Dir.pwd

        # Get what we're interested in being notified about
        notify  = @options[:notify] || []
        notify  = [notify] if !notify.is_a?(Array)
        if notify.empty? && block_given?
          # If a block is given, subscribers must be given, otherwise the
          # block is never called. This is usually NOT what you want, so this
          # is an error.
          message = "A list of notify subscriptions must be given if a block is given"
          raise ArgumentError, message
        end

        # Let's get some more useful booleans that we access a lot so
        # we're not constantly calling an `include` check
        notify_table = {}
        notify_table[:stderr] = notify.include?(:stderr)
        notify_table[:stdout] = notify.include?(:stdout)
        notify_stdin  = notify.include?(:stdin)

        # Build the ChildProcess
        @logger.info("Starting process: #{@command.inspect}")
        process = ChildProcess.build(*@command)

        # Create the pipes so we can read the output in real time as
        # we execute the command.
        stdout, stdout_writer = ::IO.pipe
        stderr, stderr_writer = ::IO.pipe
        process.io.stdout = stdout_writer
        process.io.stderr = stderr_writer
        process.duplex = true

        # If we're in an installer on Mac and we're executing a command
        # in the installer context, then force DYLD_LIBRARY_PATH to look
        # at our libs first.
        if Vagrant.in_installer? && Platform.darwin?
          installer_dir = ENV["VAGRANT_INSTALLER_EMBEDDED_DIR"].to_s.downcase
          if @command[0].downcase.include?(installer_dir)
            @logger.info("Command in the installer. Specifying DYLD_LIBRARY_PATH...")
            process.environment["DYLD_LIBRARY_PATH"] =
              "#{installer_dir}/lib:#{ENV["DYLD_LIBRARY_PATH"]}"
          else
            @logger.debug("Command not in installer, not touching env vars.")
          end

          if File.setuid?(@command[0]) || File.setgid?(@command[0])
            @logger.info("Command is setuid/setgid, clearing DYLD_LIBRARY_PATH")
            process.environment["DYLD_LIBRARY_PATH"] = ""
          end
        end

        # Set the environment on the process if we must
        if @options[:env]
          @options[:env].each do |k, v|
            process.environment[k] = v
          end
        end

        # Start the process
        begin
          SafeChdir.safe_chdir(workdir) do
            process.start
          end
        rescue ChildProcess::LaunchError => ex
          # Raise our own version of the error so that users of the class
          # don't need to be aware of ChildProcess
          raise LaunchError.new(ex.message)
        end

        # Make sure the stdin does not buffer
        process.io.stdin.sync = true

        if RUBY_PLATFORM != "java"
          # On Java, we have to close after. See down the method...
          # Otherwise, we close the writers right here, since we're
          # not on the writing side.
          stdout_writer.close
          stderr_writer.close
        end

        # Create a dictionary to store all the output we see.
        io_data = { :stdout => "", :stderr => "" }

        # Record the start time for timeout purposes
        start_time = Time.now.to_i

        @logger.debug("Selecting on IO")
        while true
          writers = notify_stdin ? [process.io.stdin] : []
          results = ::IO.select([stdout, stderr], writers, nil, timeout || 0.1)
          results ||= []
          readers = results[0]
          writers = results[1]

          # Check if we have exceeded our timeout
          raise TimeoutExceeded, process.pid if timeout && (Time.now.to_i - start_time) > timeout

          # Check the readers to see if they're ready
          if readers && !readers.empty?
            readers.each do |r|
              # Read from the IO object
              data = IO.read_until_block(r)

              # We don't need to do anything if the data is empty
              next if data.empty?

              io_name = r == stdout ? :stdout : :stderr
              @logger.debug("#{io_name}: #{data.chomp}")

              io_data[io_name] += data
              yield io_name, data if block_given? && notify_table[io_name]
            end
          end

          # Break out if the process exited. We have to do this before
          # attempting to write to stdin otherwise we'll get a broken pipe
          # error.
          break if process.exited?

          # Check the writers to see if they're ready, and notify any listeners
          if writers && !writers.empty?
            yield :stdin, process.io.stdin if block_given?
          end
        end

        # Wait for the process to end.
        begin
          remaining = (timeout || 32000) - (Time.now.to_i - start_time)
          remaining = 0 if remaining < 0
          @logger.debug("Waiting for process to exit. Remaining to timeout: #{remaining}")

          process.poll_for_exit(remaining)
        rescue ChildProcess::TimeoutError
          raise TimeoutExceeded, process.pid
        end

        @logger.debug("Exit status: #{process.exit_code}")

        # Read the final output data, since it is possible we missed a small
        # amount of text between the time we last read data and when the
        # process exited.
        [stdout, stderr].each do |io|
          # Read the extra data, ignoring if there isn't any
          extra_data = IO.read_until_block(io)
          next if extra_data == ""

          # Log it out and accumulate
          io_name = io == stdout ? :stdout : :stderr
          io_data[io_name] += extra_data
          @logger.debug("#{io_name}: #{extra_data.chomp}")

          # Yield to any listeners any remaining data
          yield io_name, extra_data if block_given?
        end

        if RUBY_PLATFORM == "java"
          # On JRuby, we need to close the writers after the process,
          # for some reason. See GH-711.
          stdout_writer.close
          stderr_writer.close
        end

        # Return an exit status container
        return Result.new(process.exit_code, io_data[:stdout], io_data[:stderr])
      end

      protected

      # An error which raises when a process fails to start
      class LaunchError < StandardError; end

      # An error which occurs when the process doesn't end within
      # the given timeout.
      class TimeoutExceeded < StandardError
        attr_reader :pid

        def initialize(pid)
          super()
          @pid = pid
        end
      end

      # Container class to store the results of executing a subprocess.
      class Result
        attr_reader :exit_code
        attr_reader :stdout
        attr_reader :stderr

        def initialize(exit_code, stdout, stderr)
          @exit_code = exit_code
          @stdout    = stdout
          @stderr    = stderr
        end
      end
    end
  end
end
