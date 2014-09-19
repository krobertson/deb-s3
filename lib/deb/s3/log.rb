require 'logger'

class Log
  def self.log
    if @logger.nil?
      @logger = Logger.new STDOUT
      @logger.level = Logger::INFO
      @logger.datetime_format = '%Y-%m-%d %H:%M:%S '
    end
    @logger
  end
end
