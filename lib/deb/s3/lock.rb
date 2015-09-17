# -*- encoding : utf-8 -*-
require "tempfile"
require "socket"
require "etc"

class Deb::S3::Lock
  attr_accessor :user
  attr_accessor :host

  def initialize
    @user = nil
    @host = nil
  end

  class << self
    def locked?(codename, component = nil, architecture = nil, cache_control = nil)
      Deb::S3::Utils.s3_exists?(lock_path(codename, component, architecture, cache_control))
    end

    def wait_for_lock(codename, component = nil, architecture = nil, cache_control = nil, max_attempts=60, wait=10)
      attempts = 0
      while self.locked?(codename, component, architecture, cache_control) do
        attempts += 1
        throw "Unable to obtain a lock after #{max_attempts}, giving up." if attempts > max_attempts
        sleep(wait)
      end
    end

    def lock(codename, component = nil, architecture = nil, cache_control = nil)
      lockfile = Tempfile.new("lockfile")
      lockfile.write("#{Etc.getlogin}@#{Socket.gethostname}")
      lockfile.close

      Deb::S3::Utils.s3_store(lockfile.path,
                              lock_path(codename, component, architecture, cache_control),
                              "text/plain",
                              cache_control)
    end

    def unlock(codename, component = nil, architecture = nil, cache_control = nil)
      Deb::S3::Utils.s3_remove(lock_path(codename, component, architecture, cache_control))
    end

    def current(codename, component = nil, architecture = nil, cache_control = nil)
      lock_content = Deb::S3::Utils.s3_read(lock_path(codename, component, architecture, cache_control))
      lock_content = lock_content.split('@')
      lock = Deb::S3::Lock.new
      lock.user = lock_content[0]
      lock.host = lock_content[1] if lock_content.size > 1
      lock
    end

    private
    def lock_path(codename, component = nil, architecture = nil, cache_control = nil)
      "dists/#{codename}/#{component}/binary-#{architecture}/lockfile"
    end
  end
end
