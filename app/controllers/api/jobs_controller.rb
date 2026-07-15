require "sidekiq/api"
require "csv"

class Api::JobsController < Api::ApplicationController
  DEFAULT_PAGE_SIZE = 25
  MAX_PAGE_SIZE = 100
  VALID_OUTPUT_FILE_FORMATS = %w[csv tsv].freeze

  # list all master jobs for the user
  def index
    page = params[:page].to_i
    page = 1 if page < 1

    page_size = params[:page_size].to_i
    page_size = DEFAULT_PAGE_SIZE if page_size < 1
    page_size = MAX_PAGE_SIZE if page_size > MAX_PAGE_SIZE

    @master_jobs = @user.master_jobs.order(created_at: :asc).page(page).per(page_size)

    render json: {
      jobs: @master_jobs.map(&:to_user_json),
      total_count: @master_jobs.total_count,
      total_pages: @master_jobs.total_pages
    }
  end

  # get the status of a master job for the user
  def show
    @master_job = @user.master_jobs.find_by(id: params[:id])
    if @master_job.present?
      render json: @master_job.to_user_json
    else
      render json: { error: "Job not found" }, status: :not_found
    end
  end

  # destroy a master job from the user
  def destroy
    begin
      @master_job = @user.master_jobs.find_by(id: params[:id])
      if @master_job.present?
        @master_job.destroy!
        render json: { message: "Job deleted" }
      else
        render json: { error: "Job not found" }, status: :not_found
      end
    rescue Exception => e
      render json: { error: "Failed to delete job: #{e.message}" }, status: :unprocessable_entity
    end
  end

  # create a new master job
  def create
    if ServerStatus.paused?
      return render json: { error: Admin::SettingsController::PAUSED_JOB_SUBMISSION_MESSAGE }, status: :service_unavailable
    end

    begin
      endpoint_name = params[:endpoint_name].presence
      raise Exception, "endpoint_name is required" unless endpoint_name

      raise Exception, "Unsupported endpoint_name: #{endpoint_name}" unless endpoint_name == "Geocode"

      output_file_format = params[:output_file_format].presence&.downcase || "csv"
      unless VALID_OUTPUT_FILE_FORMATS.include?(output_file_format)
        raise Exception, "Unsupported output_file_format: #{output_file_format}. Supported formats are: csv, tsv"
      end

      endpoint = API_PROVIDERS[0]["endpoints"].find { |e| e["name"] == "Geocode" }
      raise Exception, "Geocode endpoint config not found" unless endpoint

      job_class_name = endpoint["job_class"].presence || "GeocoderMasterJob"
      job_class = job_class_name.safe_constantize
      raise Exception, "Invalid job class: #{job_class_name}" unless job_class

      queued_jobs_count = queued_jobs_in_sidekiq(endpoint_name)

      if queued_jobs_count >= 20
        raise Exception, "You have reached the limit of 20 jobs in the queue. Please wait and try again later."
      end

      @geocoder_master_job = job_class.new(user: @user, endpoint_name: endpoint_name)
      @geocoder_master_job.output_file_format = output_file_format

      options = endpoint["default_params"].dup
      if params[:options].present?
        raw_options = params[:options]

        options =
          case raw_options
          when Array
            raw_options.map do |option|
              option = option.to_unsafe_h if option.is_a?(ActionController::Parameters)
              {
                name: option["name"] || option[:name],
                value: option["value"] || option[:value]
              }
            end
          when ActionController::Parameters, Hash
            raw_hash = raw_options.is_a?(ActionController::Parameters) ? raw_options.to_unsafe_h : raw_options

            if raw_hash.key?("name") || raw_hash.key?(:name)
              [{
                name: raw_hash["name"] || raw_hash[:name],
                value: raw_hash["value"] || raw_hash[:value]
              }]
            else
              raw_hash.map { |name, value| { name: name, value: value } }
            end
          else
            raise Exception, "options must be an array or object"
          end
      end
      @geocoder_master_job.api_options = options

      @geocoder_master_job.input_data_content_type = params[:input_data_content_type].presence || "text/csv"
      @geocoder_master_job.output_data_content_type =
        params[:output_data_content_type].presence || (output_file_format == "tsv" ? "text/tsv" : "text/csv")

      if params[:input_data].present?
        if params[:input_data_content_type].present? && params[:input_data_content_type] == "application/json"
          csv_content = convert_json_input_to_csv(params[:input_data])
          @geocoder_master_job.input_data_content_type = "text/csv"
          @geocoder_master_job.input_file.attach(
            io: StringIO.new(csv_content),
            filename: "input_#{Time.current.to_i}.csv",
            content_type: "text/csv"
          )
        elsif params[:input_data_content_type].present? && (params[:input_data_content_type] == "text/csv" || params[:input_data_content_type] == "text/tsv")
          csv_content = params[:input_data].to_s
          @geocoder_master_job.input_file.attach(
            io: StringIO.new(csv_content),
            filename: "input_#{Time.current.to_i}.csv",
            content_type: @geocoder_master_job.input_data_content_type || "text/csv"
          )
        elsif params[:input_data_content_type].blank?
          raise Exception, "input_data_content_type is required when input_data is provided"
        else
          raise Exception, "Unsupported input_data_content_type: #{@geocoder_master_job.input_data_content_type}. The supported content types are: text/csv, text/tsv, application/json"
        end
        
      elsif params[:input_data_url].present?
        url = params[:input_data_url]
        @geocoder_master_job.input_file.attach(io: URI.open(url), filename: File.basename(URI.parse(url).path))
      elsif params[:input_data_file].present?
        @geocoder_master_job.input_file.attach(params[:input_data_file])
      else
        raise Exception, "input data is required"
      end

      @geocoder_master_job.save!
      @geocoder_master_job.enqueue_sidekiq_job
      render json: @geocoder_master_job.to_user_json, status: :created
    rescue Exception => e
      render json: { error: "Failed to create job: #{e.message}" }, status: :unprocessable_entity
    end
  end

  private

  def convert_json_input_to_csv(input_data)
    parsed_json = JSON.parse(input_data.to_s)
    rows = parsed_json.is_a?(Array) ? parsed_json : [parsed_json]

    raise Exception, "JSON input must contain at least one object" if rows.blank?
    raise Exception, "JSON input must be an object or an array of objects" unless rows.all? { |row| row.is_a?(Hash) }

    headers = rows.each_with_object([]) do |row, keys|
      row.keys.each { |key| keys << key unless keys.include?(key) }
    end

    CSV.generate do |csv|
      csv << headers
      rows.each do |row|
        csv << headers.map { |header| row[header] }
      end
    end
  rescue JSON::ParserError => e
    raise Exception, "Invalid JSON input: #{e.message}"
  end

  def queued_jobs_in_sidekiq(endpoint_name)
    user_job_ids = @user.master_jobs.where(endpoint_name: endpoint_name).pluck(:id).map(&:to_s)
    return 0 if user_job_ids.empty?

    Sidekiq::Queue.all.sum do |queue|
      queue.count { |job| sidekiq_job_matches_master_job_ids?(job, user_job_ids) }
    end
  end

  def sidekiq_job_matches_master_job_ids?(job, user_job_ids)
    payload = job.item.to_json
    user_job_ids.any? do |id|
      payload.include?("/GeocoderMasterJob/#{id}") ||
        payload.match?(/"(master_job_id|geocoder_master_job_id|job_id|id)"\s*:\s*"#{Regexp.escape(id)}"/)
    end
  end
end