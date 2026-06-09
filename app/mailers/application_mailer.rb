require "json"
require "net/http"
require "uri"

class ApplicationMailer < ActionMailer::Base
  default from: "example@gov.bc.ca"
  layout "mailer"

  CHES_DEFAULT_URL = "https://ches.api.gov.bc.ca/api/v1/email".freeze
  CHES_TOKEN_URL = "https://loginproxy.gov.bc.ca/auth/realms/comsvcauth/protocol/openid-connect/token".freeze
  RESULTS_READY_SUBJECT = "LOC-CPF Results Ready".freeze
  RESULTS_READY_SENDER = "donotreply.locationservices@gov.bc.ca".freeze

  def self.send_email!(destination_address:, body:, subject: nil)
    raise ArgumentError, "destination_address is required" if destination_address.blank?
    raise ArgumentError, "body is required" if body.blank?

    email_subject = subject.presence || RESULTS_READY_SUBJECT

    bearer_token = fetch_bearer_token!
    uri = URI.parse(ENV["CHES_API_URL"].presence || CHES_DEFAULT_URL)

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{bearer_token}"
    request["Content-Type"] = "application/json"
    request.body = {
      from: RESULTS_READY_SENDER,
      to: [ destination_address ],
      subject: email_subject,
      bodyType: "text",
      body: body,
      priority: "normal",
      encoding: "utf-8"
    }.to_json

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end

    return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

    raise "CHES email send failed (#{response.code}): #{response.body}"
  end

  def self.fetch_bearer_token!
    client_id = ENV["CHES_CLIENT_ID"].presence
    client_secret = ENV["CHES_CLIENT_SECRET"].presence
    raise "CHES_CLIENT_ID is required" if client_id.blank?
    raise "CHES_CLIENT_SECRET is required" if client_secret.blank?

    token_uri = URI.parse(ENV["CHES_TOKEN_URL"].presence || CHES_TOKEN_URL)

    token_request = Net::HTTP::Post.new(token_uri)
    token_request.basic_auth(client_id, client_secret)
    token_request["Content-Type"] = "application/x-www-form-urlencoded"
    token_request["Accept"] = "application/json"
    token_request.body = URI.encode_www_form(grant_type: "client_credentials")

    token_response = Net::HTTP.start(token_uri.host, token_uri.port, use_ssl: token_uri.scheme == "https") do |http|
      http.request(token_request)
    end

    unless token_response.is_a?(Net::HTTPSuccess)
      raise "CHES token request failed (#{token_response.code}): #{token_response.body}"
    end

    token_payload = JSON.parse(token_response.body)
    access_token = token_payload["access_token"].to_s
    raise "CHES token response missing access_token" if access_token.blank?

    access_token
  end
end
