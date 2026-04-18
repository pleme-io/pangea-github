# frozen_string_literal: true
# Partial — only resources that have been hand-written post pangea-forge
# generation gap. Full regen via terraform-schema-importer is task #75
# (Phase 4f: Fix pangea-tls + pangea-github gem generation).

require 'pangea-core'
require 'terraform-synthesizer'

module Pangea; module Resources; module Github; module Types; end; end; end; end

# Github resources — hand-written minimal set
require_relative 'pangea/resources/github_repository_deploy_key/resource'
