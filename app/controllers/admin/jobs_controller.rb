class Admin::JobsController < Admin::ApplicationController
  JOBS_PER_PAGE = 10

  def index
    sort_column = params[:sort] || "created_at"
    sort_direction = params[:direction] || "desc"
    
    valid_columns = %w[id type status created_at]
    sort_column = "created_at" unless valid_columns.include?(sort_column)
    sort_direction = "desc" if sort_direction != "asc"

    @jobs = GeocoderMasterJob.order("#{sort_column} #{sort_direction}").page(params[:page]).per(JOBS_PER_PAGE)
    @sort_column = sort_column
    @sort_direction = sort_direction
  end

  def show
    @job = GeocoderMasterJob.find_by(id: params[:id])
    if @job.nil?
      redirect_to admin_jobs_path, alert: "Job not found"
    end
  end

  def cancel
    @job = GeocoderMasterJob.find_by(id: params[:id])
    if @job.nil?
      redirect_to admin_jobs_path, alert: "Job not found"
    else
      @job.cancel!
      redirect_to admin_jobs_path, notice: "Job cancelled"
    end
  end

  def destroy
    @job = GeocoderMasterJob.find_by(id: params[:id])
    if @job.nil?
      redirect_to admin_jobs_path, alert: "Job not found"
    else
      @job.destroy
      redirect_to admin_jobs_path, notice: "Job deleted"
    end
  end
end