# Class representing an autogenerated {Domain} level ssh key. These keys are generated when the BROKER_KEY_ADD
# directive is passed back from the cartridge hooks. This key is used by cartridges and applications
# like Jenkins that need to operate on other applications within the same {Domain}.
#
# @!attribute [r] domain
#   @return [Domain] The domain that owns this key.
class SystemSshKey < SshKey
  include Mongoid::Document
  embedded_in :domain, class_name: Domain.name
end