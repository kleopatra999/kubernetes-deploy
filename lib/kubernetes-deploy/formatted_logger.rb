# frozen_string_literal: true
require 'logger'

module KubernetesDeploy
  class FormattedLogger < Logger
    def self.build(namespace, context, stream = $stderr, verbose_prefix: false)
      l = new(stream)
      l.level = level_from_env

      l.formatter = proc do |severity, datetime, _progname, msg|
        middle = verbose_prefix ? "[#{context}][#{namespace}]" : ""
        colorized_line = ColorizedString.new("[#{severity}][#{datetime}]#{middle}\t#{msg}\n")

        case severity
        when "FATAL"
          colorized_line.red
        when "ERROR", "WARN"
          colorized_line.yellow
        when "INFO"
          msg =~ /^\[(KUBESTATUS|Pod)/ ? colorized_line : colorized_line.blue
        else
          colorized_line
        end
      end
      l
    end

    def self.level_from_env
      return ::Logger::DEBUG if ENV["DEBUG"]

      if ENV["LEVEL"]
        ::Logger.const_get(ENV["LEVEL"].upcase)
      else
        ::Logger::INFO
      end
    end
    private_class_method :level_from_env

    def blank_line(level = :info)
      public_send(level, "")
    end
  end
end