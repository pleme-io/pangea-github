# frozen_string_literal: true

require 'spec_helper'
require 'pangea/helpers/github_presets'

RSpec.describe Pangea::Helpers::Github do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }

  describe '.standard_repo' do
    it 'emits github_repository with pleme-io defaults' do
      described_class.standard_repo(synth, name: 'example', description: 'demo')
      result = normalize_synthesis(synth.synthesis)
      repo = validate_resource_structure(result, 'github_repository', 'example')
      expect(repo['visibility']).to eq('public')
      expect(repo['has_wiki']).to eq(false)
      expect(repo['has_projects']).to eq(false)
      expect(repo['allow_squash_merge']).to eq(true)
      expect(repo['allow_merge_commit']).to eq(false)
      expect(repo['delete_branch_on_merge']).to eq(true)
      expect(repo['vulnerability_alerts']).to eq(true)
    end

    it 'honours overrides (visibility=private, has_wiki=true)' do
      described_class.standard_repo(
        synth, name: 'internal', description: 'x',
        visibility: :private, has_wiki: true,
      )
      result = normalize_synthesis(synth.synthesis)
      repo = validate_resource_structure(result, 'github_repository', 'internal')
      expect(repo['visibility']).to eq('private')
      expect(repo['has_wiki']).to eq(true)
    end
  end

  describe '.archived_repo' do
    it 'marks the repo archived' do
      described_class.archived_repo(synth, name: 'retired', description: 'x')
      result = normalize_synthesis(synth.synthesis)
      repo = validate_resource_structure(result, 'github_repository', 'retired')
      expect(repo['archived']).to eq(true)
      expect(repo['has_issues']).to eq(false)
    end
  end

  describe '.protect_default_branch' do
    let(:repo) do
      described_class.standard_repo(synth, name: 'proj', description: 'x')
    end

    it 'standard profile: no enforce_admins, no signed commits' do
      described_class.protect_default_branch(
        synth, repo_ref: repo, repo_name: 'proj', profile: :standard,
      )
      result = normalize_synthesis(synth.synthesis)
      prot = validate_resource_structure(result, 'github_branch_protection', 'proj-main')
      expect(prot['enforce_admins']).to eq(false)
      expect(prot['require_signed_commits']).to eq(false)
      expect(prot['allows_force_pushes']).to eq(false)
      expect(prot['allows_deletions']).to eq(false)
    end

    it 'hardened profile: enforces admins, signed commits, linear history' do
      described_class.protect_default_branch(
        synth, repo_ref: repo, repo_name: 'proj', profile: :hardened,
      )
      result = normalize_synthesis(synth.synthesis)
      prot = validate_resource_structure(result, 'github_branch_protection', 'proj-main')
      expect(prot['enforce_admins']).to eq(true)
      expect(prot['require_signed_commits']).to eq(true)
      expect(prot['required_linear_history']).to eq(true)
    end

    it 'raises on unknown profile' do
      expect {
        described_class.protect_default_branch(
          synth, repo_ref: repo, repo_name: 'proj', profile: :paranoid,
        )
      }.to raise_error(ArgumentError, /unknown profile/)
    end
  end

  describe '.team_with_members' do
    it 'emits team + member + repo rows' do
      described_class.team_with_members(
        synth, name: 'core',
        members: [{ username: 'alice', role: 'maintainer' }, { username: 'bob' }],
        repos: [{ name: 'proj', permission: 'admin' }],
      )
      result = normalize_synthesis(synth.synthesis)
      expect(result.dig('resource', 'github_team', 'core')).not_to be_nil
      memberships = result.dig('resource', 'github_team_membership') || {}
      expect(memberships.keys).to contain_exactly('core-alice', 'core-bob')
      expect(memberships['core-alice']['role']).to eq('maintainer')
      expect(memberships['core-bob']['role']).to eq('member')
      repos = result.dig('resource', 'github_team_repository') || {}
      expect(repos.keys).to contain_exactly('core-proj')
      expect(repos['core-proj']['permission']).to eq('admin')
    end
  end

  describe '.repo_environment_with_secrets' do
    let(:repo) do
      described_class.standard_repo(synth, name: 'proj', description: 'x')
    end

    it 'emits environment + scoped secrets + variables' do
      described_class.repo_environment_with_secrets(
        synth, repo_ref: repo, repo_name: 'proj', env_name: 'release',
        secrets: [{ name: 'CRATES_IO_TOKEN', plaintext_ref: '${data.sops_file.secrets.data["crates_io_token"]}' }],
        variables: [{ name: 'RUSTC_WRAPPER', value: 'sccache' }],
      )
      result = normalize_synthesis(synth.synthesis)
      expect(result.dig('resource', 'github_repository_environment', 'proj-release')).not_to be_nil
      secrets = result.dig('resource', 'github_actions_environment_secret') || {}
      expect(secrets.keys).to contain_exactly('proj-release-crates_io_token')
      expect(secrets['proj-release-crates_io_token']['plaintext_value']).to match(/\A\$\{/)
      vars = result.dig('resource', 'github_actions_environment_variable') || {}
      expect(vars.keys).to contain_exactly('proj-release-rustc_wrapper')
      expect(vars['proj-release-rustc_wrapper']['value']).to eq('sccache')
    end
  end

  describe '.repo_actions_secrets' do
    it 'bulk-emits github_actions_secret resources' do
      described_class.repo_actions_secrets(
        synth, repo_name: 'proj',
        entries: [
          { name: 'ALPHA', plaintext_ref: '${a}' },
          { name: 'BETA',  plaintext_ref: '${b}' },
        ],
      )
      result = normalize_synthesis(synth.synthesis)
      secrets = result.dig('resource', 'github_actions_secret') || {}
      expect(secrets.keys).to contain_exactly('proj-alpha', 'proj-beta')
    end
  end

  describe '.validate_topics' do
    it 'accepts valid topics sorted+deduplicated' do
      out = described_class.validate_topics(%w[rust cli rust gitops])
      expect(out).to eq(%w[cli gitops rust])
    end

    it 'rejects uppercase' do
      expect { described_class.validate_topics(%w[Rust]) }
        .to raise_error(ArgumentError, /lowercase/)
    end

    it 'rejects too long' do
      long = 'a' * 36
      expect { described_class.validate_topics([long]) }
        .to raise_error(ArgumentError, /1–35 chars/)
    end

    it 'rejects too many (21+)' do
      topics = (0..20).map { |i| "topic-#{i}" }
      expect { described_class.validate_topics(topics) }
        .to raise_error(ArgumentError, /at most 20 topics/)
    end
  end
end
