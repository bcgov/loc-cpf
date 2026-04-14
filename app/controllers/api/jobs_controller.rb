class Api::JobsController < Api::ApplicationController
  DEFAULT_PAGE_SIZE = 25

  # list all master jobs for the user
  def index
    page = params[:page].to_i
    page = 1 if page < 1

    page_size = params[:page_size].to_i
    page_size = DEFAULT_PAGE_SIZE if page_size < 1

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
    begin
      endpoint_name = params[:endpoint_name].presence
      raise Exception, "endpoint_name is required" unless endpoint_name

      raise Exception, "Unsupported endpoint_name: #{endpoint_name}" unless endpoint_name == "Geocode"

      endpoint = API_PROVIDERS[0]["endpoints"].find { |e| e["name"] == "Geocode" }
      raise Exception, "Geocode endpoint config not found" unless endpoint

      @geocoder_master_job = @user.geocoder_master_jobs.new(endpoint_name: endpoint_name)

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
      @geocoder_master_job.output_data_content_type = params[:output_data_content_type].presence || "text/csv"

      if params[:input_data_url].present?
        url = params[:input_data_url]
        @geocoder_master_job.input_file.attach(io: URI.open(url), filename: File.basename(URI.parse(url).path))
      elsif params[:input_data_file].present?
        @geocoder_master_job.input_file.attach(params[:input_data_file])
      else
        raise Exception, "input data is required"
      end

      @geocoder_master_job.save!
      render json: { id: @geocoder_master_job.id }, status: :created
    rescue Exception => e
      render json: { error: "Failed to create job: #{e.message}" }, status: :unprocessable_entity
    end
  end
end