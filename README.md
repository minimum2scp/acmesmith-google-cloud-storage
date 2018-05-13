# acmesmith-google-cloud-storage

This gem is a plugin for [Acmesmith](https://github.com/sorah/acmesmith) and implements storage using [Google Cloud Storage](https://cloud.google.com/storage/)

## Usage

### Prerequisites

 * You need to have service account of Google Cloud Platform to operate Google Cloud Storage via API.

### Installation

Install `acmesmith-google-cloud-storage` gem along with `acmesmith`. You can just do `gem install acmesmith-google-cloud-storage` or use Bundler if you want.

### Configuration

Use `google_cloud_storage` storage in your acmesmith.yml. General instructions about acmesmith.yml is available in the manual of Acmesmith.

```yaml
endpoint: https://acme-staging.api.letsencrypt.org/
# endpoint: https://acme-v01.api.letsencrypt.org/ # productilon

storage:
  type: google_cloud_storage
  bucket: 
  prefix: 
  compute_engine_service_account: true # (pick-one): You can use GCE VM instance scope
  private_key_json_file: /path/to/credential.json # (pick-one) Only JSON key file is supported

challenge_responders:
  # configure how to respond ACME challenges; see the manual of Acmesmith.
```

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

