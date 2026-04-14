class GeocoderMasterJob < MasterJob

  def to_user_json
    {
      id: id,
      status: self.get_status,
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
      input_file_url: input_file.attached? ? Rails.application.routes.url_helpers.rails_blob_url(input_file, disposition: "attachment", only_path: true) : nil,
      output_file_url: output_file.attached? ? Rails.application.routes.url_helpers.rails_blob_url(output_file, disposition: "attachment", only_path: true) : nil,
      options: self.api_options
    }
  end
end