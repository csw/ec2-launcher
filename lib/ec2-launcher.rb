require 'fog'
require 'erb'
require 'mime'
#require 'pathname'
require 'stringio'
require 'yaml'

module EC2Launcher
  class UserDataBuilder
    attr_reader :user_data, :mime, :msg

    TEMPLATE_DIR = File.expand_path('../user-data-templates')

    TYPE_MAP = {
      /^#include/        => 'text/x-include-url',
      /^#!/              => 'text/x-shellscript',
      /^#cloud-config/   => 'text/cloud-config',
      /^#upstart-job/    => 'text/upstart-job',
      /^#part-handler/   => 'text/part-handler',
      /^#cloud-boothook/ => 'text/cloud-boothook'
    }

    def initialize
      @mime = MIME::MultipartMedia::Mixed.new
      @msg = MIME::Message.new(@mime)
    end

    def templates
      Dir.glob("#{TEMPLATE_DIR}/??-*").sort
    end

    def mime_type_for(part)
      TYPE_MAP.each do |start, type|
        return type if part =~ start
      end
      raise "could not determine MIME type for part: #{part}"
    end

    def gzipped(content)
      buffer = StringIO.new
      gz = Zlib::GzipWriter.new(buffer)
      gz.write(content)
      return buffer.string
    end

    def mime_cleanup(orig)
      # remove Content-ID lines, for a start
      # total kludge but never mind
      buf = ''
      orig.each_line do |line|
        unless line =~ /^Content-ID: /
          buf << line
        end
      end
      buf
    end

    def generate(gzip=false)
      templates.reverse.each do |tpath|
        template = ERB.new(File.read(tpath))
        payload = template.result
        mime.attach_entity(MIME::TextMedia.new(payload, mime_type_for(payload)),
                           :filename => File.basename(tpath))
        raw_user_data = msg.to_s #mime_cleanup(mime.to_s)
        if gzip || raw_user_data.bytesize > 16384
          @user_data = gzipped(raw_user_data)
        else
          @user_data = raw_user_data
        end
      end
    end
  end

  class Launcher
    attr_reader :conn

    def initialize
      cfg_path = ENV['AWS_KEYS']
      if cfg_path && File.exist?(cfg_path)
        keys = YAML.load_file(cfg_path)
      else
        raise "AWS_KEYS environment variable must point to AWS credentials!"
      end
      fog_opts = {
        :provider => 'AWS',
        :aws_access_key_id => keys[:access_key_id],
        :aws_secret_access_key => keys[:secret_access_key]
      }
      @conn = Fog::Compute.new(fog_opts)
    end

    def launch_spot(opts)
      opts[:price] ||= '0.01'
      # can get JSON table of Ubuntu AMIs from
      # http://cloud.ubuntu.com/ami-locator/releasesTable
      # and can get region string with conn.instance_variable_get(:@region)
      # (yes, really, it's not exposed otherwise...')
      opts[:image_id] ||= 'ami-a29943cb'
      opts[:flavor_id] ||= 't1.micro'
      opts[:key_name] ||= 'maf'
      r = conn.spot_requests.create(opts)
    end
  end

end
