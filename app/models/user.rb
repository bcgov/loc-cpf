class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, 
         # :registerable,
         # :recoverable, 
         # :rememberable,
         # :lockable,
         :validatable,
         authentication_keys: [:client_id]

  has_many :tokens, dependent: :destroy
  has_many :jobs, dependent: :destroy
  has_many :master_jobs, -> { where(type: ["MasterJob", "GeocoderMasterJob"]) }, class_name: "Job"
  has_many :geocoder_master_jobs, -> { where(type: "GeocoderMasterJob") }, class_name: "Job"

  validates :email, allow_blank: true, uniqueness: false
  validates :client_id, allow_blank: true, uniqueness: true

  # Devise :validatable requires email by default; override since we auth via client_id
  def email_required?
    false
  end

  def password_required?
    new_record?
  end

  def ifAdmin?
    self.admin.present? && self.admin
  end

  def self.find_or_create_the_dummy_user
    user = User.find_or_initialize_by(client_id: "dummy_user")
    if user.new_record?
      user.email = "test@example.com"
      user.password = Devise.friendly_token[0, 20]
      user.display_name = "Dummy User"
      user.idir_username = "DUMMYUSER"
      user.save!
    end
    user
  end

  # this method should be called before any action. Kong will attach a header HTTP_X_USER_INFO
  # with a base64 encoded token, which contains user information. We will create the user in db if not exist, 
  # and use the user for authentication and authorization in the app.
  # example parsed token: {
    # "email":"mike.zhou@gov.bc.ca",
    # "preferred_username":"e45288c60ea7429f830ab0f555c1bf06@azureidir",
    # "username":"e45288c60ea7429f830ab0f555c1bf06@azureidir",
    # "name":"Zhou, Mike CITZ:EX",
    # "id":"e45288c60ea7429f830ab0f555c1bf06@azureidir",
    # "idir_user_guid":"E45288C60EA7429F830AB0F555C1BF06",
    # "given_name":"Mike","user_principal_name":"Mike.Zhou@gov.bc.ca",
    # "display_name":"Zhou, Mike CITZ:EX",
    # "identity_provider":"azureidir",
    # "idir_username":"MIZHOU","client_roles":["Admin"],
    # "sub":"e45288c60ea7429f830ab0f555c1bf06@azureidir",
    # "session_state":"2c50aff4-5be4-4180-0b18-8d2000f6b8a2",
    # "family_name":"Zhou"}
  def self.find_or_create_from_kong(token)
    begin
      user_info = JSON.parse(Base64.decode64(token))
      user = User.find_or_initialize_by(client_id: user_info["client_id"])
      user.email = user_info["email"]
      user.password = Devise.friendly_token[0, 20] if user.new_record?
      user.display_name = user_info["display_name"] if user_info["display_name"].present?
      user.idir_username = user_info["idir_username"] if user_info["idir_username"].present?
      user.admin = user_info["client_roles"].include?("Admin") if user_info["client_roles"].present?
      user.save!
      user
    rescue => e
      Rails.logger.error("Failed to find or create user from Kong token: #{e.message}")
      nil
    end
  end

  # this method creates or finds a user based on the Kong consumer ID, which is used for Kong-authenticated requests without SSO token.
  def self.find_or_create_from_consumer(consumer_id, consumer_username)
    begin
      user = User.find_or_initialize_by(client_id: consumer_id)
      if user.new_record?
        user.display_name = consumer_username
        user.password = Devise.friendly_token[0, 20]
        user.save!
      end
      user
    rescue => e
      Rails.logger.error("Failed to find or create user from Kong consumer ID: #{e.message}")
      nil
    end
  end
end
