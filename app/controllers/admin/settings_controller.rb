class Admin::SettingsController < Admin::ApplicationController
  PAUSED_JOB_SUBMISSION_MESSAGE = "Job submissions are currently disabled by system admin. This is usually due to maintenance or other administrative reasons. Please try again later."

  def index
    @server_status = ServerStatus.current.status
  end

  def toggle_server_status
    record = ServerStatus.toggle!
    redirect_to admin_settings_path, notice: "Server is now #{record.status}."
  end
end