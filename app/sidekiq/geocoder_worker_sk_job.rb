require "csv"
require "stringio"
require "net/http"
require "uri"

class GeocoderWorkerSkJob
  include Sidekiq::Job

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

      # step 2: perform geocoding and collect output rows
      sequence_number = 0
      total_row_count = 0
      output_rows = []

      csv.each do |row|
        next if row.fields.all?(&:blank?)

        total_row_count += 1
        sequence_number = row[0] # assuming the first column is sequence number, if not, we can also just use the index of the row in the CSV
        your_id = row["yourId"]

        params = normalize_api_options(job.api_options)
        default_params = endpoint["default_params"] || {}

        csv.headers.each do |header|
          next unless default_params.key?(header)
          value = row[header]
          params[header] = value unless value.blank?
        end

        next if params["addressString"].blank?

        begin
          result = call_geocoder_api(params)
          features = result["features"] || []
          execution_time = result["executionTime"]

          if features.empty?
            output_rows << build_empty_output_row(output_headers, sequence_number, row["yourId"])
          else
            # Note: only take the first feature
            feature = features.first
            props = feature["properties"] || {}
            coords = feature.dig("geometry", "coordinates")
            location = coords ? "SRID=4326;POINT(#{coords[0]} #{coords[1]})" : nil
            faults = Array(props["faults"]).map { |f| "#{f["value"]}.#{f["element"]}:#{f["penalty"]}" rescue f.to_s }.join(", ")

            # prepare output row based on output_headers config
            output_row = output_headers.map do |header|
              case header
              when "sequenceNumber" then sequence_number
              when "resultNumber"   then 1
              when "yourId"         then your_id
              when "location"       then location
              when "faults"         then faults.present? ? "[#{faults}]" : ""
              when "executionTime"  then execution_time
              else
                props[header] || ""
              end
            end

            output_rows << output_row
          end
        rescue => api_error
          Rails.logger.warn "Geocoder API failed for row #{sequence_number}: #{api_error.message}"
          output_rows << build_empty_output_row(output_headers, sequence_number, your_id)
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

      job.update!(completed_at: Time.now, result_created_at: Time.now, success: true, total_rows: total_row_count)
      
      # step 4: update master job's completed_jobs count atomically
      if job.master_job_id.present?
        Job.increment_counter(:completed_jobs, job.master_job_id)
        job.master_job.generate_result_file
      end
    rescue => e
      job.update!(completed_at: Time.now, success: false)
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
end
