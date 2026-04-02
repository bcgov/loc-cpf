class JobsController < ApplicationController
  # before_action :authenticate_user!

  def index
    @master_jobs = MasterJob.order(created_at: :desc).page(params[:page]).per(10)
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