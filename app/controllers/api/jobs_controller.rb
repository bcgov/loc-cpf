class Api::JobsController < Api::ApplicationController

  def index
    @master_jobs = MasterJob.order(created_at: :desc)
    render json: {
      master_jobs: @master_jobs.as_json(only: [:id, :status, :created_at, :updated_at])
    }
  end

  def show
    @master_job = MasterJob.find(params[:id])
    @worker_jobs = @master_job.worker_jobs.order(created_at: :asc)
  end

  def create
  end

  def destroy
  end

  def update
  end
end