# this file loads all the configuration for CPF from CONFIGMAP files
require 'yaml'
require "erb"

raw = ERB.new(File.read(Rails.root.join("config", "cpf_config.yaml"))).result
file = YAML.safe_load(raw, aliases: true) || {}
if development?
  all_configs = file["data"] || {}
  embedded = all_configs["cpf_config.yaml"]
  CPF_CONFIG =
    case embedded
    when String
      YAML.safe_load(embedded, aliases: true) || {}
    when Hash
      embedded
    else
      {}
    end
else
  CPF_CONFIG = file || {}
end

API_PROVIDERS = CPF_CONFIG["api_providers"] || {}
WORKER_OPTIONS = CPF_CONFIG["worker_options"] || {}
