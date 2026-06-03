# the Job manager manages the status of all jobs. It has methods to ensure
# the jobs are properly enqueued, started or failed expecially from
# system failures.
class JobManager

  # the main method to check all jobs and ensure they are enqueued, started or failed properly.
  # This method is called periodically by a cronjob to ensure the jobs are properly managed.
  # The general recovery plan
  # - The system is not expected to be HA 24/7 service. We allow some interruption such as cluster failure to happen. However, after the interruption the service should be self healing: 
  #   All apps and components should self heal to the state before the failure automatically (system level)
  #   All submitted jobs should retry and completes (application/data level). 
  #   Partially submitted jobs will be ignored
  # - A Reconciler CronJob runs periodically to scan MySQL for jobs in non-terminal states (for example: submitted, scheduled, in_progress, finalizing). It compares database state with Redis/Valkey queue state and detects interrupted or missing enqueued work.
  #   If a job is recoverable, the reconciler re-enqueues missing master/worker jobs. If a job exceeds timeout or retry limits, it is marked failed with a clear error_message.
  # - The reconciler also handles long-running stale jobs by stopping/re-enqueuing them when safe and idempotent.
  #   If required artifacts are missing (for example input/output files in SeaweedFS, or required job metadata in MySQL), the job is treated as non-recoverable and marked failed gracefully.
  def self.check_jobs
    non_terminal_statuses = %w[submitted scheduled in_progress finalizing]

    Job.find_each do |job|
      begin
        next unless non_terminal_statuses.include?(job.get_status)
        reconcile_job(job)
      rescue => e
        Rails.logger.error("[JobManager] reconcile error job_id=#{job&.id}: #{e.class}: #{e.message}")
      end
    end
  end

  class << self
    private

    def reconcile_job(job)
      job.reload if job.respond_to?(:reload)
      return if job.is_terminal_status? # double check the status after acquiring lock, in case it has been updated by other process

      if job.is_missing_required_artifacts?
        return job.update!(
          completed_at: Time.current,
          success: false,
          error_message: "Non-recoverable: required artifacts/metadata are missing"
        )
      end

      if job.reach_max_attempts?
        return job.update!(
          completed_at: Time.current,
          success: false,
          error_message: "Recovery limits exceeded: timeout or retry limit reached"
        )
      end

      # let's skip stale check for now
      # if job.is_stale?
      #   # restart job if it is safely recoverable (for example, the job is idempotent and can be safely re-enqueued without side effects); 
      #   # otherwise, mark it failed to avoid potential issues from unsafe retries 
      #   # note: we changed the stale definition so it will be jobs that has been started but
      #   # is not found in worker list. We assume all jobs will end eventually because it makes
      #   # api calls with timeout settings. So we just need to reenqueue the job if it is stale, no need to stop them.
      #   if job.kind_of?(MasterJob)
      #     job.reenqueue_sidekiq_job
      #   elsif job.kind_of?(WorkerJob)
      #     job.reenqueue_sidekiq_job
      #   else
      #     Rails.logger.warn("Unknown job type for job_id=#{job.id}, cannot reconcile")
      #   end
      # end

      if job.missing_from_all_sidekiq_states?
        # job is non-terminal, not running, and not found in queue/scheduled/retry/dead
        if job.kind_of?(MasterJob)
          job.reenqueue_sidekiq_job
        elsif job.kind_of?(WorkerJob)
          job.reenqueue_sidekiq_job
        else
          Rails.logger.warn("Unknown job type for job_id=#{job.id}, cannot reconcile")
        end
      end
    end
  end
end