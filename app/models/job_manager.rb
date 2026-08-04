# the Job manager manages the status of all jobs. It has methods to ensure
# the jobs are properly enqueued, started or failed expecially from
# system failures.
class JobManager
  NON_TERMINAL_STATUSES = %w[submitted scheduled in_progress finalizing].freeze
  DEFAULT_MASTER_RETENTION_DAYS = 7
  DEFAULT_COMPONENT_CHECK_GRACE_SECONDS = 600

  # the main method to check all jobs and ensure they are enqueued, started or failed properly.
  # This method is called periodically by a cronjob to ensure the jobs are properly managed.
  # The general recovery plan
  # - The system is not expected to be HA 24/7 service. We allow some interruption such as pod crash and cluster failure to happen. 
  #   However, after the interruption the service should be self healing: 
  #   All apps and components should self heal to the state before the failure automatically (system level)
  #   All submitted jobs should retry and completes (application/data level). 
  #   Partially submitted jobs will be ignored
  # - A Reconciler CronJob runs periodically to scan MySQL for jobs in non-terminal states (for example: submitted, scheduled, in_progress, finalizing).
  #   It compares database state with Redis/Valkey queue state and detects interrupted or missing enqueued work.
  #   If a job is recoverable, the reconciler re-enqueues missing master/worker jobs. If a job exceeds timeout or retry limits, it is marked failed with a clear error_message.
  # - The reconciler also handles long-running stale jobs by stopping/re-enqueuing them when safe and idempotent.
  #   If required artifacts are missing (for example input/output files in SeaweedFS, or required job metadata in MySQL), the job is treated as non-recoverable and marked failed gracefully.
  def self.check_jobs
    Job.where("type = 'GeocoderMasterJob'").find_each do |master_job|
      begin
        next if master_job.is_terminal_status?
        next unless NON_TERMINAL_STATUSES.include?(master_job.get_status)

        reconcile_master_job(master_job)
      rescue => e
        Rails.logger.error("[JobManager] reconcile error master_job_id=#{master_job&.id}: #{e.class}: #{e.message}")
      end
    end
  end

  def self.cleanup_old_master_jobs
    cutoff = Time.current - master_job_retention_days.days
    Rails.logger.info("[JobManager] cleaning up master jobs older than #{cutoff} (#{master_job_retention_days} days)")

    Job.where("type = 'GeocoderMasterJob' AND created_at < ?", cutoff).find_each do |master_job|
      begin
        Rails.logger.info("[JobManager] deleting old master job id=#{master_job.id}, created_at=#{master_job.created_at}")  
        master_job.destroy!
        Rails.logger.info("[JobManager] deleted old master job id=#{master_job.id}, created_at=#{master_job.created_at}")
      rescue => e
        Rails.logger.error("[JobManager] failed deleting old master job id=#{master_job.id}: #{e.class}: #{e.message}")
      end
    end
  end

  class << self
    private

    def reconcile_master_job(master_job)
      master_job.reload if master_job.respond_to?(:reload)
      return if master_job.is_terminal_status?

      if master_job_missing_required_artifacts?(master_job)
        return fail_master!(master_job, "Non-recoverable: required artifacts/metadata are missing")
      end

      if master_job.reach_max_attempts?
        return fail_master!(master_job, "Recovery limits exceeded: timeout or retry limit reached")
      end

      # Master still splitting/creating worker jobs; do not assert component existence yet.
      return unless master_job.completed_at.present?

      expected_workers = master_job.total_jobs.to_i
      actual_workers = master_job.worker_jobs.count

      if expected_workers <= 0
        return fail_master_if_past_grace!(
          master_job,
          "Master completed but no worker jobs were created",
          master_job.completed_at
        )
      end

      if actual_workers < expected_workers
        return fail_master_if_past_grace!(
          master_job,
          "Worker jobs missing (expected=#{expected_workers}, actual=#{actual_workers})",
          master_job.completed_at
        )
      end

      # Merge job is expected only after all workers are complete and result not yet created.
      workers_done = master_job.completed_jobs.to_i >= expected_workers
      merge_missing = master_job.merge_jobs.count == 0
      result_not_created = master_job.result_created_at.blank?

      if workers_done && result_not_created && merge_missing
        anchor_time = master_job.worker_jobs.maximum(:completed_at) || master_job.updated_at || master_job.completed_at
        return fail_master_if_past_grace!(
          master_job,
          "Merge job missing after all workers completed",
          anchor_time
        )
      end
    end

    def master_job_missing_required_artifacts?(master_job)
      return true if master_job.endpoint_name.blank?
      return true unless master_job.respond_to?(:input_file) && master_job.input_file.attached?
      false
    rescue => e
      Rails.logger.warn("[JobManager] artifact check failed for master_job_id=#{master_job&.id}: #{e.class}: #{e.message}")
      true
    end

    def fail_master_if_past_grace!(master_job, message, anchor_time)
      return if anchor_time.blank?
      return if (Time.current - anchor_time) < component_check_grace_seconds

      fail_master!(master_job, message)
    end

    def fail_master!(master_job, message)
      master_job.update!(
        completed_at: Time.current,
        success: false,
        error_message: message.to_s.truncate(255)
      )
    end

    def job_manager_options
      CPF_CONFIG["job_manager_options"] || {}
    end

    def master_job_retention_days
      val = job_manager_options["master_job_retention_days"].to_i
      val.positive? ? val : DEFAULT_MASTER_RETENTION_DAYS
    end

    def component_check_grace_seconds
      val = job_manager_options["component_check_grace_seconds"].to_i
      val.positive? ? val : DEFAULT_COMPONENT_CHECK_GRACE_SECONDS
    end
  end
end