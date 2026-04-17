# README

This README would normally document whatever steps are necessary to get the
application up and running.

Things you may want to cover:

* Ruby version

* System dependencies

* Configuration

* Database creation

* Database initialization

* How to run the test suite

* Services (job queues, cache servers, search engines, etc.)

* Deployment instructions

* ...
# loc-cpf

python3 sample_client_script.py 

Run SeaweedFS locally:


export AWS_ACCESS_KEY_ID=local_test_key_id
export AWS_SECRET_ACCESS_KEY=local_test_secret
export AWS_S3_BUCKET=cpf

./seaweedfs/weed mini -dir=./seaweedfs/data
S3 Endpoint http://localhost:8333

Run Valkey
brew services start valkey
brew services stop valkey
brew services info valkey

bundle exec sidekiq