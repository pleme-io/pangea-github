# frozen_string_literal: true
# Hand-written minimal typescape for integrations/github github_repository_deploy_key
# until pangea-forge + terraform-schema-importer regenerate the full set.
# Matches the structural pattern of pangea-aws/<resource>/types.rb.

require 'pangea/resources/base_attributes'

module Pangea::Resources::Github::Types
  include Dry.Types()

  class RepositoryDeployKeyAttributes < Pangea::Resources::BaseAttributes
    T = Pangea::Resources::Github::Types

    # Required. Repository slug (no owner prefix — provider-scoped).
    attribute :repository, T::String

    # Required. Human-readable title for the deploy key.
    attribute :title, T::String

    # Required. Public-key blob (openssh format).
    attribute :key, T::String

    # Optional. When true, key is read-only (flux needs write for bootstrap).
    attribute? :read_only, T::Bool.optional
  end
end
