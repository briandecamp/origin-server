# Primary User model for the broker. It keeps track of plan details, capabilities and ssh-keys for the user.
# @!attribute [r] login
#   @return [String] Login name for the user.
# @!attribute [r] capabilities
#   @return [Hash] Hash representing the capabilities of the user. It is updated using the ss-admin-user-ctl scripts or when a plan changes.
# @!attribute [r] parent_user_id
#   @return [Moped::BSON::ObjectId] ID of the parent user object if this object prepresents a sub-account.
# @!attribute [rw] plan_id
# @!attribute [rw] pending_plan_id
# @!attribute [rw] pending_plan_uptime
# @!attribute [rw] usage_account_id
# @!attribute [rw] consumed_gears
#   @return [Integer] Number of gears that are being consumed by applications owned by this user
# @!attribute [r] ssh_keys
#   @return [Array[SshKey]] SSH keys used to access applications that the user has access to or owns
#     @see {#add_ssh_key}, {#remove_ssh_key}, and {#update_ssh_key}
# @!attribute [r] pending_ops
#   @return [Array[PendingUserOps]] List of {PendingUserOps} objects
class CloudUser
  include Mongoid::Document
  include Mongoid::Timestamps
  
  DEFAULT_SSH_KEY_NAME = "default"

  field :login, type: String
  field :capabilities, type: Hash, default: {"subaccounts" => false, "gear_sizes" => ["small"], "max_gears" => 3}
  field :parent_user_id, type: Moped::BSON::ObjectId
  field :plan_id, type: String
  field :pending_plan_id, type: String
  field :pending_plan_uptime, type: String
  field :usage_account_id, type: String
  field :consumed_gears, type: Integer, default: 0
  embeds_many :ssh_keys, class_name: SshKey.name
  embeds_many :pending_ops, class_name: PendingUserOps.name
  
  validates :login, presence: true, login: true
  validates :capabilities, presence: true, capabilities: true
  
  # Returns a map of field to error code for validation failures.
  def self.validation_map
    {login: 107, capabilities: 107}
  end
  
  # Auth method can either be :login or :broker_auth. :login represents a normal authentication with user/pass.
  # :broker_auth is used when the applciation needs to make a request to the broker on behalf of the user (eg: scale-up)
  def auth_method=(m)
    @auth_method = m
  end
  
  # @see #auth_method=
  def auth_method
    @auth_method
  end
  
  # Convinience method to get the max_gears capability
  def max_gears
    self.capabilities["max_gears"]
  end
  
  # Used to add an ssh-key to the user. Use this instead of ssh_keys= so that the key can be propogated to the
  # domains/applicaiton that the user has access to.
  def add_ssh_key(key)
    domains = Domain.where(owner: self) + Domain.where(user_ids: self._id)
    if domains.count > 0
      pending_op = PendingUserOps.new(op_type: :add_ssh_key, arguments: key.attributes.dup, state: :init, on_domain_ids: domains.map{|d|d._id.to_s}, created_at: Time.new)
      CloudUser.where(_id: self.id).update_all({ "$push" => { pending_ops: pending_op.serializable_hash , ssh_keys: key.serializable_hash }})
      self.reload
      self.run_jobs
    else
      self.ssh_keys.push key
    end
    self
  end
  
  # Used to update an ssh-key on the user. Use this instead of ssh_keys= so that the key update can be propogated to the
  # domains/applicaiton that the user has access to.
  def update_ssh_key(key)
    raise "noimpl"
  end
  
  # Used to remove an ssh-key from the user. Use this instead of ssh_keys= so that the key removal can be propogated to the
  # domains/applicaiton that the user has access to.
  def remove_ssh_key(name)
    key = self.ssh_keys.find_by(name: name)
    domains = Domain.where(owner: self) + Domain.where(user_ids: self._id)
    if domains.count > 0
      pending_op = PendingUserOps.new(op_type: :delete_ssh_key, arguments: key.attributes.dup, state: :init, on_domain_ids: domains.map{|d|d._id.to_s}, created_at: Time.new)
      CloudUser.where(_id: self.id).update_all({ "$push" => { pending_ops: pending_op.serializable_hash } , "$pull" => { ssh_keys: key.serializable_hash }})
      self.reload
      self.run_jobs      
    else
      key.delete
    end
    self
  end
  
  def domains
    Domain.where(owner: self) + Domain.where(user_ids: self._id)
  end
  
  # Runs all jobs in :init phase and stops at the first failure.
  #
  # == Returns:
  # True on success or false on failure
  def run_jobs
    begin
      ops = pending_ops.where(state: :init)
      ops.each do |op|
        case op.op_type
        when :add_ssh_key
          op.pending_domains.each { |domain| domain.add_ssh_key(self._id, op.arguments, op) }
        when :delete_ssh_key
          op.pending_domains.each { |domain| domain.remove_ssh_key(self._id, op.arguments, op) }
        end
        begin
          self.pending_ops.find_by(_id: op._id, :state.ne => :completed).set(state: :queued)
        rescue Mongoid::Errors::DocumentNotFound
          #ignore. Op state is completed
        end
      end
      true
    rescue Exception => ex
      Rails.logger.error ex
      Rails.logger.error ex.backtrace
      false
    end
  end
end