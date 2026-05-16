require "csv"
require "stringio"
require "net/http"
require "uri"

class GeocoderWorkerSkJob
  include Sidekiq::Job

  ERROR_HEADERS = ["sequenceNumber", "yourId", "addressString", "errorMessage"].freeze
  UNSET_MARKER_PARAMS = %w[streetDirection extrapolate].freeze

  sidekiq_options retry: false, queue: :geocoder_worker_sk_job, backtrace: false

  def perform(job_id)
    job = Job.find_by(id: job_id)

    ### identify the associated job
    # check if job exists and has the correct jid
    if job.nil?
      Rails.logger.info "Job not found: #{job_id}, Sidekiq JID: #{self.jid}"
      return
    end

    if job.jid.present? && job.jid != self.jid
      Rails.logger.info "JID mismatch for Job ID: #{job_id}, Sidekiq JID: #{self.jid}, Job JID: #{job.jid}"
      return
    end
    if job.jid.nil?
      job.update!(jid: self.jid)
    end

    # fail fast if master job already failed
    if job.master_job_id.present?
      master_job = Job.find_by(id: job.master_job_id)
      if master_job&.success == false
        job.update!(
          started_at: Time.now,
          completed_at: Time.now,
          success: false,
          error_message: "worker_skipped: master job failed".truncate(255)
        )
        return
      end
    end

    ### perform the geocoding task
    begin
      endpoint = API_PROVIDERS[0]["endpoints"].find { |e| e["name"] == "Geocode" }
      output_headers = endpoint["output_headers"] || []
      raise "output_headers not configured for Geocode endpoint" if output_headers.empty?

      if job.type != "GeocoderWorkerJob"
        raise "Job ID: #{job_id} is not a GeocoderWorkerJob, actual type: #{job.type}"
      end
      job.update!(started_at: Time.now)

      # step 1: download the input file from ActiveStorage (this should be good to fit in memory)
      input_content = job.input_file.download
      delimiter = job.input_data_content_type.to_s.downcase.include?("tsv") ? "\t" : ","
      csv = CSV.parse(input_content, headers: true, col_sep: delimiter)

      output_rows = []
      error_rows = []

      # step 2: perform geocoding and collect output rows
      csv.each do |row|
        next if row.fields.all?(&:blank?)

        ### For input formats. There are two types of format both are valid csv/tsv format.
        ### Format 1: There is only one column addressString.
        ### Format 2: There are multiple columns. addressString is required. sequenceNumber and yourId are optional, 
        ### other columns can be used as additional parameters for geocoding API

        sequence_number = row["sequenceNumber"].presence || row["N"].presence || ""
        your_id = row["yourId"] || ""
        address_string = row["addressString"]

        begin
          if address_string.blank?
            raise "addressString is blank"
          end

          default_params = endpoint["default_params"] || {}
          params = build_geocoder_params(
            default_params: default_params,
            api_options: normalize_api_options(job.api_options),
            row: row,
            headers: csv.headers
          )

          address_string = params["addressString"]
          raise "addressString is blank" if address_string.blank?

          result = call_geocoder_api(params)

          feature = (result["features"] || []).first
          raise "No geocoding result returned" if feature.blank?

          props = feature["properties"] || {}
          coords = feature.dig("geometry", "coordinates")
          full_address = props["fullAddress"] || ""
          location = coords ? "SRID=4326;POINT(#{coords[0]} #{coords[1]})" : nil
          faults = format_faults(props["faults"])
          execution_time = result["executionTime"]

          # prepare output row based on output_headers config
          output_row = output_headers.map do |header|
            case header
            when "sequenceNumber" then sequence_number
            when "fullAddress"    then full_address
            when "resultNumber"   then 1
            when "yourId"         then your_id
            when "location"       then location
            when "faults"         then faults
            when "executionTime"  then execution_time
            else
              props[header] || ""
            end
          end

          output_rows << output_row
        rescue => row_error
          output_rows << build_failed_output_row(output_headers, row, sequence_number, your_id)
          error_rows << [sequence_number, your_id, address_string, row_error.message.to_s]
        end
      end

      # step 3: write output CSV and attach to job
      output_csv = CSV.generate do |out|
        out << output_headers
        output_rows.each { |r| out << r }
      end

      job.output_file.attach(
        io: StringIO.new(output_csv),
        filename: "job_#{job.id}_output.csv",
        content_type: "text/csv"
      )

      if error_rows.any?
        error_csv = CSV.generate do |out|
          out << ERROR_HEADERS
          error_rows.each { |r| out << r }
        end

        job.error_file.attach(
          io: StringIO.new(error_csv),
          filename: "job_#{job.id}_errors.csv",
          content_type: "text/csv"
        )
      else
        job.error_file.purge if job.error_file.attached?
      end

      job.update!(
        completed_at: Time.now,
        result_created_at: Time.now,
        success: true,
        total_rows: output_rows.size + error_rows.size,
        error_message: (error_rows.any? ? "Worker completed with #{error_rows.size} failed rows" : nil)
      )

      # step 4: update master job's completed_jobs count atomically
      if job.master_job_id.present?
        Job.increment_counter(:completed_jobs, job.master_job_id)
        job.master_job.generate_result_file
      end
    rescue => e
      job.update!(
        completed_at: Time.now,
        success: false,
        error_message: "Worker failed: #{e.message}".truncate(255)
      )
      Rails.logger.error "Error processing Job ID: #{job_id}, error: #{e.message}"
    end
  end

  private

  def build_empty_output_row(output_headers, sequence_number, your_id = nil)
    row = Array.new(output_headers.size, nil)

    sequence_idx = output_headers.index("sequenceNumber")
    result_idx   = output_headers.index("resultNumber")
    your_id_idx  = output_headers.index("yourId")

    row[sequence_idx] = sequence_number unless sequence_idx.nil?
    row[result_idx]   = 0 unless result_idx.nil?
    row[your_id_idx]  = your_id unless your_id_idx.nil?

    row
  end

  def call_geocoder_api(params)
    provider = API_PROVIDERS.find { |p| p["name"] == "BC Address Geocoder" } || API_PROVIDERS.first
    raise "Geocoder provider config not found" if provider.blank?

    endpoint = provider["endpoints"]&.find { |e| e["name"] == "Geocode" }
    raise "Geocode endpoint config not found" if endpoint.blank?

    host = provider["host"].to_s
    path = endpoint["path"].to_s
    raise "Geocoder host/path config missing" if host.blank? || path.blank?

    request_path = path.end_with?(".json") ? path : "#{path}.json"
    uri = URI.join(host, request_path)

    query = params.to_h.each_with_object({}) do |(k, v), out|
      next if v.nil? || v.to_s.strip.empty?
      out[k.to_s] = v
    end
    uri.query = URI.encode_www_form(query)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    request["Accept"] = "application/json"

    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      raise "Geocoder API request failed: HTTP #{response.code} - #{response.body}"
    end

    json = JSON.parse(response.body)
  end

  def normalize_api_options(raw)
    value = raw
    2.times do
      break unless value.is_a?(String)
      begin
        value = JSON.parse(value)
      rescue JSON::ParserError
        break
      end
    end
    value.is_a?(Hash) ? value : {}
  end

  def build_geocoder_params(default_params:, api_options:, row:, headers:)
    defaults = (default_params || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    allowed_keys = defaults.keys

    # keep request options not present in CSV headers, but only if allowlisted
    filtered_api_options = sanitize_allowlisted_params(api_options, allowed_keys)
    params = defaults.merge(filtered_api_options)

    # CSV values override request/default values when allowlisted and non-blank
    Array(headers).each do |header|
      key = header.to_s
      next unless allowed_keys.include?(key)
      value = row[header]
      params[key] = value unless value.blank?
    end

    remove_unset_marker_params(params)
  end

  def remove_unset_marker_params(params)
    UNSET_MARKER_PARAMS.each do |key|
      params.delete(key) if params[key].to_s.strip == "--"
    end
    params
  end

  def sanitize_allowlisted_params(source, allowed_keys)
    return {} unless source.is_a?(Hash)

    source.each_with_object({}) do |(k, v), out|
      key = k.to_s
      next unless allowed_keys.include?(key)
      next if v.nil? || v.to_s.strip.empty?
      out[key] = v
    end
  end

  def build_failed_output_row(output_headers, row, sequence_number, your_id)
    output_headers.map do |header|
      case header
      when "sequenceNumber" then sequence_number
      when "resultNumber"   then 0
      when "yourId"         then your_id
      when "score"          then 0
      else
        # keep original row value when header exists in input; otherwise empty geocoder result
        row.header?(header) ? (row[header] || "") : ""
      end
    end
  end

  def format_faults(raw_faults)
    formatted = Array(raw_faults).filter_map do |fault|
      next if fault.blank?
      element = fault["element"].to_s.presence
      fault_name = fault["fault"].to_s.presence
      penalty = fault["penalty"]
      next if element.blank? || fault_name.blank? || penalty.nil?

      "#{element}.#{fault_name}:#{penalty}"
    rescue
      nil
    end

    formatted.any? ? "[#{formatted.join(', ')}]" : ""
  end
end
