require 'acmesmith/storages/base'
require 'acmesmith/account_key'
require 'acmesmith/certificate'

require 'google/apis/storage_v1'
require 'open-uri'
require 'stringio'

module Acmesmith
  module Storages
    class GoogleCloudStorage < Base
      attr_reader :bucket, :prefix, :compute_engine_service_account, :private_key_json_file

      def initialize(bucket:, prefix:, compute_engine_service_account:nil, private_key_json_file:nil)
        @bucket = bucket
        @prefix = prefix
        if @prefix && !@prefix.end_with?('/')
          @prefix += '/'
        end
        @compute_engine_service_account = compute_engine_service_account
        @private_key_json_file = private_key_json_file

        @scope = 'https://www.googleapis.com/auth/devstorage.read_write'
        @api = Google::Apis::StorageV1::StorageService.new
        if @compute_engine_service_account
          @api.authorization = Google::Auth.get_application_default(@scope)
        elsif @private_key_json_file
          credential = load_json_key(@private_key_json_file)
          @api.authorization = Signet::OAuth2::Client.new(
            token_credential_uri: "https://accounts.google.com/o/oauth2/token",
            audience: "https://accounts.google.com/o/oauth2/token",
            scope: @scope,
            issuer: credential[:email_address],
            signing_key: credential[:private_key])
        else
          raise "You need to specify authentication options (compute_engine_service_account or private_key_json_file)"
        end
        @api.authorization.fetch_access_token!
      end

      def get_account_key
        obj = @api.get_object(bucket, account_key_key)
        media = get_media(obj.media_link)
        AccountKey.new media
      rescue Google::Apis::ClientError => e
        if e.status_code == 404
          raise NotExist.new("Account key doesn't exist")
        else
          raise e
        end
      end

      def account_key_exist?
        begin
          get_account_key
        rescue NotExist
          return false
        else
          return true
        end
      end

      def put_account_key(key, passphrase = nil)
        raise AlreadyExist if account_key_exist?
        obj = Google::Apis::StorageV1::Object.new(
          name: account_key_key,
          content_type: 'application/x-pem-file'
        )
        @api.insert_object(bucket, obj, upload_source: StringIO.new(key.export(passphrase)))
      end

      def put_certificate(cert, passphrase = nil, update_current: true)
        h = cert.export(passphrase)

        put = -> (key, body) do
          obj = Google::Apis::StorageV1::Object.new(
            name: key,
            content_type: 'application/x-pem-file',
          )
          @api.insert_object(bucket, obj, upload_source: StringIO.new(body))
        end

        put.call certificate_key(cert.common_name, cert.version), "#{h[:certificate].rstrip}\n"
        put.call chain_key(cert.common_name, cert.version), "#{h[:chain].rstrip}\n"
        put.call fullchain_key(cert.common_name, cert.version), "#{h[:fullchain].rstrip}\n"
        put.call private_key_key(cert.common_name, cert.version), "#{h[:private_key].rstrip}\n"

        if update_current
          @api.insert_object(
            bucket,
            Google::Apis::StorageV1::Object.new(name: certificate_current_key(cert.common_name), content_type: 'text/plain'),
            upload_source: StringIO.new(cert.version),
          )
        end
      end

      def get_certificate(common_name, version: 'current')
        version = certificate_current(common_name) if version == 'current'

        certificate = get_media(@api.get_object(bucket, certificate_key(common_name, version)).media_link)
        chain       = get_media(@api.get_object(bucket, chain_key(common_name, version)).media_link)
        private_key = get_media(@api.get_object(bucket, private_key_key(common_name, version)).media_link)
        Certificate.new(certificate, chain, private_key)
      rescue Google::Apis::ClientError => e
        if e.status_code == 404
          raise NotExist.new("Certificate for #{common_name.inspect} of #{version} version doesn't exist")
        else
          raise e
        end
      end

      def list_certificates
        certs_prefix = "#{prefix}certs/"
        objects = @api.fetch_all do |token, s|
          s.list_objects(bucket, prefix: certs_prefix, page_token: token)
        end
        objects.map{ |obj|
          regexp = /\A#{Regexp.escape(certs_prefix)}/
          obj.name.sub(regexp, '').sub(/\/.+\z/, '').sub(/\/\z/, '')
        }.uniq
      end

      def list_certificate_versions(common_name)
        cert_ver_prefix = "#{prefix}certs/#{common_name}/"
        objects = @api.fetch_all do |token, s|
          s.list_objects(bucket, prefix: cert_ver_prefix, page_token: token)
        end
        objects.map { |obj|
          regexp = /\A#{Regexp.escape(cert_ver_prefix)}/
          obj.name.sub(regexp, '').sub(/\/.+\z/, '').sub(/\/\z/, '')
        }.uniq.reject { |_| _ == 'current' }
      end

      def get_current_certificate_version(common_name)
        certificate_current(common_name)
      end

      private

      def account_key_key
        "#{prefix}account.pem"
      end

      def certificate_base_key(cn, ver)
        "#{prefix}certs/#{cn}/#{ver}"
      end

      def certificate_current_key(cn)
        certificate_base_key(cn, 'current')
      end

      def certificate_current(cn)
        obj = @api.get_object(bucket, certificate_current_key(cn))
        get_media(obj.media_link).chomp
      rescue Google::Apis::ClientError => e
        if e.status_code == 404
          raise NotExist.new("Certificate for #{cn.inspect} of current version doesn't exist")
        else
          raise e
        end
      end

      def certificate_key(cn, ver)
        "#{certificate_base_key(cn, ver)}/cert.pem"
      end

      def private_key_key(cn, ver)
        "#{certificate_base_key(cn, ver)}/key.pem"
      end

      def chain_key(cn, ver)
        "#{certificate_base_key(cn, ver)}/chain.pem"
      end

      def fullchain_key(cn, ver)
        "#{certificate_base_key(cn, ver)}/fullchain.pem"
      end

      def get_media(media_link)
        open(media_link, {'Authorization' => "Bearer #{@api.authorization.access_token}"}).read
      end

      def load_json_key(filepath)
        obj = JSON.parse(File.read(filepath))
        {
          email_address: obj["client_email"],
          private_key: OpenSSL::PKey.read(obj["private_key"]),
        }
      end
    end
  end
end