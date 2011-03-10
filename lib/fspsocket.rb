#!/usr/bin/env ruby
#
# = FSPSocket module
# Author:: mokitma@gmail.com
# Copyright:: Copyright 2011 mokitma
#
# Supports lazy socket communication over file synchronization services,
# namely Dropbox
#
require 'rubygems'
require 'fileutils'
require 'socket'
require 'singleton'
require 'observer'
require 'filemonitor'
require 'uri'
require 'json'
require 'drb/drb'
require 'logger'

module FSPSocket
  @@log = Logger.new(STDOUT)
  @@log.level = Logger::WARN
  @@base = [ENV['HOME'], "Dropbox", "socks"].join(File::SEPARATOR)

  def FSPSocket.new
    return PSocket.new
  end

  def FSPSocket.open(dst_id, &block)
    return PSocket.open(dst_id, block)
  end

  class PSocket 
    include FSPSocket
    @@id_count = 0
    attr_reader :id

    def initialize(*args)
      @host = Socket.gethostname
      @pid = Process.pid
      @id = [@host, @pid, @@id_count].join('_')
      @@id_count += 1
      if args.length == 1
        @block = args[0]
      end
      @sock_buf = []
      Manager.instance.add_observer self
      init_channel
    end

    def init_channel
      unless FileTest.exist? @@base
        Dir::mkdir(@@base, 0777)
      end

      @path = [@@base, @id].join(File::SEPARATOR)
      @cpath = [@path, :controls].join(File::SEPARATOR)
      @dpath = [@path, :data].join(File::SEPARATOR)
      @connected = [] # for cleanup 
      unless FileTest.exist? @path
        Dir::mkdir(@path, 0777)
        Dir::mkdir(@cpath, 0777)
        FileUtils.touch(@dpath)
      end
      Manager.instance.add_dir(@cpath)
    end
    private :init_channel
  
    # msg[0] => path, msg[1] => data in JSON delimited with '\n'  
    def update(msg)
      @@log.info "--- update #{msg}"
      # msg[1]:data part can contain more than one line
      msg[1].each_line do |item|
        h = JSON.parse(item) 
        d = h.fetch(:data.to_s) 
        ud = URI.unescape(d)
        ar = ud.split
        if ar[0] == "HELLO"
          @@log.info "---got HELLO: #{ar[1]}"
          Manager.instance.add_file([@@base, ar[1], :data].join(File::SEPARATOR))
          # XXX
          mycpath = [@@base, ar[1], :controls, @id].join(File::SEPARATOR)
          FileUtils.touch(mycpath)
          sleep 1 # XXX for timing purpose
          PSocket.write_to(mycpath, "OK #{@id}")
        elsif ar[0] == "OK"
          @@log.info "---got OK: #{ar[1]}"
          Manager.instance.add_file([@@base, ar[1], :data].join(File::SEPARATOR))
          @block.call(method(:received))    
        elsif ar[0] == "BYE"
          @@log.info "---got BYE: #{ar[1]}"
          Manager.instance.remove_file([@@base, ar[1], :data].join(File::SEPARATOR))
        else
          @recv_block.call(msg[0], ud)
        end    
      end # each
    end

    def connect_channel(dst_fullpath)
      # 1. create my controls channel in the other's controls dir 
      #    /socks/dstid/controls/myid
      mycpath = [dst_fullpath, :controls, @id].join(File::SEPARATOR)
      @connected << mycpath
      FileUtils.touch(mycpath)
      sleep 1 # XXX for timing purpose
      # 2. let the other know my path
      PSocket.write_to(mycpath, "HELLO #{@id}")    
    end

    def delete_channel
      @connected.each do |path|
        if FileTest.exist? path
          File::delete path
        end
      end

      path = [@@base, @id].join(File::SEPARATOR)
      if FileTest.exist? path
        File::delete [path, :data].join(File::SEPARATOR)
        FileUtils.rm_rf path
      end    
    end 

    def PSocket.open(dst_id, block)
      sock = PSocket.new(block)
      if (dst_id.kind_of?(Enumerable))
        dst_id.each do |item|
          sock.connect_channel([@@base, item].join(File::SEPARATOR))
        end
      else
        sock.connect_channel([@@base, dst_id].join(File::SEPARATOR))
      end
      return sock
    end

    # used to connect to multiple destinations
    def connect(dst_id)
      if (dst_id.kind_of?(Enumerable))
        dst_id.each do |item|
          connect_channel([@@base, item].join(File::SEPARATOR))
        end
      else
        connect_channel([@@base, dst_id].join(File::SEPARATOR))
      end
    end

    def close
      delete_channel
      PSocket.write_to(@dst_cpath, "BYE #{@id}") 
    end

    def received(&block)
      @recv_block = block
    end 

    def puts(data)
      #@@log.debug "XXX puts: #{@dpath} #{data}"
      PSocket.write_to(@dpath, data)
    end

    def PSocket.write_to(path, data)
      @@log.info "write_to #{path} #{data}"
      File::open(path, "a+") do |f|
        h = {:time=>Time.now, :data=>URI.encode(data)}
        f.puts(h.to_json)
      end    
    end

    alias_method :_puts, :puts 
    private :_puts
  end # class

  class Manager
    include FSPSocket
    include Singleton
    include Observable
    attr_reader :m

    def initialize
      @paths = {}
      @m = FileMonitor.new do |f|
        @@log.info "Modified: #{f.path}"
        file_modified(f.path)
      end
    end

    def add_dir(path)
      @@log.info "add_dir: #{path}"
      @m.add(path) do |f|
        @@log.info "dir modified #{f.path}"
        @paths.store(f.path, [0, 0]) # dummy data
        file_modified(f.path)
      end
    end 

    def add_file(path)
      @@log.info "add_file: #{path}"
      st = File::stat(path)
      @paths.store(path, [st.mtime, st.size])
      @m << path
    end
 
    def remove_file(path)
      @paths.delete(path)
    end

    def get_file
      @paths.each_key
    end

    def file_modified(path)
      @@log.info "file_modifled: #{path}" 
      prev = @paths.fetch(path)
      st = File::stat(path)
      open(path, "r") do |f|
        f.seek(prev[1], IO::SEEK_SET)
        data = f.read(st.size - prev[1])      
        @@log.info "data: #{data}"
        begin
          changed
          idpart = path.sub(@@base, "").split(File::Separator)[1]
          notify_observers [idpart, data] # XXX May contain multiple json entries
        rescue
          STDERR.puts $!
        end
      end # open
      @paths.store(path, [st.mtime, st.size]) 
    end  

    def file_deleted(path)
      @@log.info "file_deleted: #{path}" 
      @paths.delete(path)
    end
  end # class 

  Thread.new do # called when the module is loaded
    Manager.instance.m.monitor
  end
end # module


if __FILE__ == $0
  # FSPSocket.new
end
