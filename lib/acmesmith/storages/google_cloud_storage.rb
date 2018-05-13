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

      def initialize(bucket:, prefix:nil, compute_engine_service_account:nil, private_key_json_file:nil)
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
        @api.get_object(bucket, account_key_key)
        AccountKey.new @api.get_object(bucket, account_key_key, download_dest: StringIO.new).string
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
        @api.insert_object(
          bucket,
          obj,
          upload_source: StringIO.new(key.export(passphrase)),
          content_type: 'application/x-pem-file',
        )
      end

      def put_certificate(cert, passphrase = nil, update_current: true)
        h = cert.export(passphrase)

        put = -> (key, body) do
          obj = Google::Apis::StorageV1::Object.new(
            name: key,
            content_type: 'application/x-pem-file',
          )
          @api.insert_object(
            bucket,
            obj,
            upload_source: StringIO.new(body),
            content_type: 'application/x-pem-file',
          )
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
            content_type: 'text/plain',
          )
        end
      end

      def get_certificate(common_name, version: 'current')
        version = certificate_current(common_name) if version == 'current'

        get = ->(key) do
          @api.get_object(bucket, key, download_dest: StringIO.new).string
        end

        certificate = get.call(certificate_key(common_name, version))
        chain       = get.call(chain_key(common_name, version))
        private_key = get.call(private_key_key(common_name, version))
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
        certs_prefix_regexp = /\A#{Regexp.escape(certs_prefix)}/
        list = []
        page_token = nil
        loop do
          objects = @api.list_objects(bucket, prefix: certs_prefix, delimiter: '/', page_token: page_token)
          if objects.prefixes
            list.concat objects.prefixes.map{|_| _.sub(certs_prefix_regexp, '').sub(/\/.+\z/,'').sub(/\/\z/, '')}
          end
          break if objects.next_page_token.nil? || objects.next_page_token == page_token
          page_token = objects.next_page_token
        end
        list.uniq
      end

      def list_certificate_versions(common_name)
        cert_ver_prefix = "#{prefix}certs/#{common_name}/"
        cert_ver_prefix_regexp = /\A#{Regexp.escape(cert_ver_prefix)}/
        list = []
        page_token = nil
        loop do
          objects = @api.list_objects(bucket, prefix: cert_ver_prefix, delimiter: '/', page_token: page_token)
          if objects.prefixes
            list.concat objects.prefixes.map{|_| _.sub(cert_ver_prefix_regexp, '').sub(/\/.+\z/, '').sub(/\/\z/, '') }
          end
          break if objects.next_page_token.nil? || objects.next_page_token == page_token
          page_token = objects.next_page_token
        end
        list.uniq.reject{ |_| _ == 'current' }
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
        @api.get_object(bucket, certificate_current_key(cn))
        @api.get_object(bucket, certificate_current_key(cn), download_dest: StringIO.new).string.chomp
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
