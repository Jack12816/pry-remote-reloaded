require 'pry'
require 'slop'
require 'drb'
require 'readline'
require 'open3'

module PryRemoteReloaded
  DefaultHost = ENV['PRY_REMOTE_DEFAULT_HOST'] || "127.0.0.1"
  DefaultPort = ENV['PRY_REMOTE_DEFAULT_PORT'] || 9876

  # A class to represent an input object created from DRb. This is used because
  # Pry checks for arity to know if a prompt should be passed to the object.
  #
  # @attr [#readline] input Object to proxy
  InputProxy = Struct.new :input do
    # Reads a line from the input
    def readline(prompt)
      case readline_arity
      when 1 then input.readline(prompt)
      else        input.readline
      end
    end

    def completion_proc=(val)
      input.completion_proc = val
    end

    def readline_arity
      input.method_missing(:method, :readline).arity
    rescue NameError
      0
    end
  end

  # Class used to wrap inputs so that they can be sent through DRb.
  #
  # This is to ensure the input is used locally and not reconstructed on the
  # server by DRb.
  class IOUndumpedProxy
    include DRb::DRbUndumped

    def initialize(obj)
      @obj = obj
    end

    def completion_proc=(val)
      if @obj.respond_to? :completion_proc=
        @obj.completion_proc = proc { |*args, &block| val.call(*args, &block) }
      end
    end

    def completion_proc
      @obj.completion_proc if @obj.respond_to? :completion_proc
    end

    def readline(prompt)
      if Readline == @obj
        @obj.readline(prompt, true)
      elsif @obj.method(:readline).arity == 1
        @obj.readline(prompt)
      else
        $stdout.print prompt
        @obj.readline
      end
    end

    def puts(*lines)
      @obj.puts(*lines)
    end

    def print(*objs)
      @obj.print(*objs)
    end

    def printf(*args)
      @obj.printf(*args)
    end

    def write(data)
      @obj.write data
    end

    def <<(data)
      @obj << data
      self
    end

    # Some versions of Pry expect $stdout or its output objects to respond to
    # this message.
    def tty?
      false
    end
  end

  # Ensure that system (shell command) output is redirected for remote session.
  System = proc do |output, cmd, _|
    status = nil
    Open3.popen3 cmd do |stdin, stdout, stderr, wait_thr|
      stdin.close # Send EOF to the process

      until stdout.eof? and stderr.eof?
        if res = IO.select([stdout, stderr])
          res[0].each do |io|
            next if io.eof?
            output.write io.read_nonblock(1024)
          end
        end
      end

      status = wait_thr.value
    end

    unless status.success?
      output.puts "Error while executing command: #{cmd}"
    end
  end

  ClientEditor = proc do |initial_content, line|
    # Hack to use Pry::Editor
    Pry::Editor.new(Pry.new).edit_tempfile_with_content(initial_content, line)
  end

  # A client is used to retrieve information from the client program.
  Client = Struct.new(:input, :output, :thread, :stdout, :stderr,
                      :editor) do
    # Waits until both an input and output are set
    def wait
      sleep 0.01 until input and output and thread
    end

    # Tells the client the session is terminated
    def kill
      thread.run
    end

    # @return [InputProxy] Proxy for the input
    def input_proxy
      InputProxy.new input
    end
  end

  class Server
    def self.run(object, host = DefaultHost, port = DefaultPort, options = {})
      new(object, host, port, options).run
    end

    def initialize(object, host = DefaultHost, port = DefaultPort, options = {})
      @host    = host
      @port    = port

      @object  = object
      @options = options

      @client = PryRemoteReloaded::Client.new
      DRb.start_service uri, @client
    rescue Errno::EADDRINUSE => e
      puts "[pry-remote] Port already in use: #{e.message}"
    end

    # Code that has to be called for Pry-remote to work properly
    def setup
      @hooks = Pry::Hooks.default

      @hooks.add_hook :before_eval, :pry_remote_capture do
        capture_output
      end

      @hooks.add_hook :after_eval, :pry_remote_uncapture do
        uncapture_output
      end

      # Before Pry starts, save the pager config.
      # We want to disable this because the pager won't do anything useful in
      # this case (it will run on the server).
      Pry.config.pager, @old_pager = false, Pry.config.pager

      # As above, but for system config
      Pry.config.system, @old_system = PryRemoteReloaded::System, Pry.config.system

      Pry.config.editor, @old_editor = editor_proc, Pry.config.editor
    end

    # Code that has to be called after setup to return to the initial state
    def teardown
      # Reset config
      Pry.config.editor = @old_editor
      Pry.config.pager  = @old_pager
      Pry.config.system = @old_system

      puts "[pry-remote] Remote session terminated"

      begin
        @client.kill
      rescue DRb::DRbConnError, Errno::ECONNREFUSED
        puts "[pry-remote] Continuing to stop service"
      ensure
        puts "[pry-remote] Ensure stop service"
        DRb.stop_service
      end
    end

    # Captures $stdout and $stderr if so requested by the client.
    def capture_output
      @old_stdout, $stdout = if @client.stdout
                               [$stdout, @client.stdout]
                             else
                               [$stdout, $stdout]
                             end

      @old_stderr, $stderr = if @client.stderr
                               [$stderr, @client.stderr]
                             else
                               [$stderr, $stderr]
                             end
    end

    # Resets $stdout and $stderr to their previous values.
    def uncapture_output
      $stdout = @old_stdout
      $stderr = @old_stderr
    end

    def editor_proc
      proc do |file, line|
        File.write(file, @client.editor.call(File.read(file), line))
      end
    end

    # Actually runs pry-remote
    def run
      puts "[pry-remote] Waiting for client on #{uri}"
      @client.wait

      puts "[pry-remote] Client received, starting remote session"
      setup

      Pry.start(@object, @options.merge(:input => client.input_proxy,
                                        :output => client.output,
                                        :hooks => @hooks))
    rescue => e
      puts "[pry-remote] Error: #{e.message}"
    ensure
      teardown
    end

    # @return Object to enter into
    attr_reader :object

    # @return [PryServer::Client] Client connecting to the pry-remote server
    attr_reader :client

    # @return [String] Host of the server
    attr_reader :host

    # @return [Integer] Port of the server
    attr_reader :port

    # @return [String] URI for DRb
    def uri
      "druby://#{host}:#{port}"
    end
  end

  # Parses arguments and allows to start the client.
  class CLI
    def initialize(args = ARGV)
      params = Slop.parse args, :help => true do
        banner "#$PROGRAM_NAME [OPTIONS]"

        on :s, :server=, "Host of the server (#{DefaultHost})", :argument => :optional,
           :default => DefaultHost
        on :p, :port=, "Port of the server (#{DefaultPort})", :argument => :optional,
           :as => Integer, :default => DefaultPort
        on :w, :wait, "Wait for the pry server to come up",
           :default => false
        on :r, :persist, "Persist the client to wait for the pry server to come up each time",
           :default => false
        on :c, :capture, "Captures $stdout and $stderr from the server (true)",
           :default => true
        on :f, "Disables loading of .pryrc and its plugins, requires, and command history "
      end

      exit if params.help?

      @host = params[:server]
      @port = params[:port]

      @wait = params[:wait]
      @persist = params[:persist]
      @capture = params[:capture]

      Pry.initial_session_setup unless params[:f]
    end

    # @return [String] Host of the server
    attr_reader :host

    # @return [Integer] Port of the server
    attr_reader :port

    # @return [String] URI for DRb
    def uri
      "druby://#{host}:#{port}"
    end

    attr_reader :wait
    attr_reader :persist
    attr_reader :capture
    alias wait? wait
    alias persist? persist
    alias capture? capture

    def run
      while true
        connect
        break unless persist?
      end
    end

    # Connects to the server
    #
    # @param [IO] input  Object holding input for pry-remote
    # @param [IO] output Object pry-debug will send its output to
    def connect(input = Pry.config.input, output = Pry.config.output)
      local_ip = UDPSocket.open {|s| s.connect(@host, 1); s.addr.last}
      DRb.start_service "druby://#{local_ip}:0"
      client = DRbObject.new(nil, uri)

      cleanup(client)

      input  = IOUndumpedProxy.new(input)
      output = IOUndumpedProxy.new(output)

      begin
        client.input  = input
        client.output = output
      rescue DRb::DRbConnError => ex
        if wait? || persist?
          sleep 1
          retry
        else
          raise ex
        end
      end

      if capture?
        client.stdout = $stdout
        client.stderr = $stderr
      end

      client.editor = ClientEditor

      client.thread = Thread.current

      sleep
    rescue Interrupt
      Pry.run_command('exit', context: Pry.binding_for(Object.new))
      puts "\n"
    ensure
      DRb.stop_service
    end

    # Clean up the client
    def cleanup(client)
      begin
        # The method we are calling here doesn't matter.
        # This is a hack to close the connection of DRb.
        client.cleanup
      rescue DRb::DRbConnError, NoMethodError
      end
    end
  end
end

class Object
  # Starts a remote Pry session
  #
  # @param [String]  host Host of the server
  # @param [Integer] port Port of the server
  # @param [Hash] options Options to be passed to Pry.start
  def remote_pry(host = PryRemoteReloaded::DefaultHost, port = PryRemoteReloaded::DefaultPort, options = {})
    PryRemoteReloaded::Server.new(self, host, port, options).run
  end

  # a handy alias as many people may think the method is named after the gem
  # (pry-remote)
  alias pry_remote remote_pry
end
