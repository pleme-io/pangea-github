# frozen_string_literal: true
#
# Pangea::Helpers::Github — hand-written composite "molecule" helpers that
# sit alongside the 85 auto-generated resource functions and compose them
# into one-call patterns we reuse across every architecture.
#
# Goal: maximize re-usability. Every time two or more architectures need
# to emit "repo + protection + the usual settings" or "team + members +
# repo access" or "environment + secrets" in the same shape, the helper
# lives here instead of being duplicated.
#
# Design principle: helpers NEVER hide non-obvious Terraform behavior.
# They default to sensible, secure values but every knob remains
# overridable through keyword arguments. Every helper returns the raw
# ResourceReference(s) so the caller can .ref(:id) downstream.

require 'pangea-github'

module Pangea
  module Helpers
    module Github
      # Idempotent guard — ensures the synthesizer has the github_*
      # resource method set before any helper call. Safe to invoke
      # repeatedly; no-op if already extended.
      def self._ensure_extended(synth)
        synth.extend(Pangea::Resources::Github) unless synth.respond_to?(:github_repository)
      end

      # ══════════════════════════════════════════════════════════════
      # Repo presets
      # ══════════════════════════════════════════════════════════════

      # Standard pleme-io public repo shape: delete-branch-on-merge,
      # squash-only, wiki/projects/downloads off, vuln alerts on.
      # Override any knob via kwargs.
      def self.standard_repo(synth, name:, description:, visibility: 'public',
                             topics: [], **overrides)
        _ensure_extended(synth)
        defaults = {
          name: name,
          description: description,
          visibility: visibility.to_s,
          topics: topics,
          has_issues: true,
          has_discussions: false,
          has_wiki: false,
          has_projects: false,
          has_downloads: false,
          allow_squash_merge: true,
          allow_merge_commit: false,
          allow_rebase_merge: false,
          delete_branch_on_merge: true,
          auto_init: false,
          archived: false,
          vulnerability_alerts: true,
        }
        synth.github_repository(:"#{name}", defaults.merge(overrides))
      end

      # Archive-mode repo shape: everything locked, no merges, read-only.
      # For repos we've retired but don't want to delete.
      def self.archived_repo(synth, name:, description:, visibility: 'public', **overrides)
        standard_repo(synth, name: name, description: description, visibility: visibility,
                      archived: true, has_issues: false, **overrides)
      end

      # ══════════════════════════════════════════════════════════════
      # Branch protection presets
      # ══════════════════════════════════════════════════════════════

      BRANCH_PROTECTION_PROFILES = {
        pilot: {
          enforce_admins: false,
          require_signed_commits: false,
          required_linear_history: false,
        }.freeze,
        standard: {
          enforce_admins: false,
          require_signed_commits: false,
          required_linear_history: false,
        }.freeze,
        hardened: {
          enforce_admins: true,
          require_signed_commits: true,
          required_linear_history: true,
        }.freeze,
      }.freeze

      # Branch protection for a repo's default branch. Locks force-pushes
      # and deletions in every profile. Profile controls admin
      # enforcement, signed commits, linear history.
      def self.protect_default_branch(synth, repo_ref:, repo_name:, branch: 'main',
                                      profile: :standard, **overrides)
        _ensure_extended(synth)
        presets = BRANCH_PROTECTION_PROFILES.fetch(profile) do
          raise ArgumentError,
                "unknown profile #{profile.inspect}, expected one of " \
                "#{BRANCH_PROTECTION_PROFILES.keys.inspect}"
        end
        defaults = {
          repository_id:          repo_ref.ref(:node_id),
          pattern:                branch,
          allows_deletions:       false,
          allows_force_pushes:    false,
        }.merge(presets)
        synth.github_branch_protection(:"#{repo_name}-#{branch}", defaults.merge(overrides))
      end

      # ══════════════════════════════════════════════════════════════
      # Team presets
      # ══════════════════════════════════════════════════════════════

      # One call provisions a team + all members + all repo access rows.
      # Returns { team:, memberships: [...], repo_access: [...] }.
      #
      # members :: Array<{ username:, role: "member" | "maintainer" }>
      # repos   :: Array<{ name:, permission: "pull"|"triage"|"push"|"maintain"|"admin" }>
      def self.team_with_members(synth, name:, description: '', privacy: 'closed',
                                 members: [], repos: [], **team_overrides)
        _ensure_extended(synth)
        team = synth.github_team(:"#{name}", {
          name:        name,
          description: description,
          privacy:     privacy,
        }.merge(team_overrides))

        memberships = members.map do |m|
          synth.github_team_membership(:"#{name}-#{m[:username]}", {
            team_id:  team.ref(:id),
            username: m[:username],
            role:     (m[:role] || 'member').to_s,
          })
        end

        repo_access = repos.map do |r|
          synth.github_team_repository(:"#{name}-#{r[:name]}", {
            team_id:    team.ref(:id),
            repository: r[:name],
            permission: (r[:permission] || 'push').to_s,
          })
        end

        { team: team, memberships: memberships, repo_access: repo_access }
      end

      # ══════════════════════════════════════════════════════════════
      # Environment + secret presets
      # ══════════════════════════════════════════════════════════════

      # Per-repo environment + all env-scoped secrets + variables.
      # Returns { env:, secrets: [...], variables: [...] }.
      #
      # secrets   :: Array<{ name:, plaintext_ref: }>
      # variables :: Array<{ name:, value: }>
      def self.repo_environment_with_secrets(synth, repo_ref:, repo_name:, env_name:,
                                             secrets: [], variables: [],
                                             reviewers: [], wait_timer: nil, **env_overrides)
        _ensure_extended(synth)
        env_args = {
          repository:  repo_ref.ref(:name),
          environment: env_name,
        }
        env_args[:wait_timer] = wait_timer if wait_timer
        # reviewers is an array of { users: [...], teams: [...] } objects.
        # Pangea generator emits this as the full nested block shape.
        env_args[:reviewers] = reviewers unless reviewers.empty?

        env = synth.github_repository_environment(
          :"#{repo_name}-#{env_name}",
          env_args.merge(env_overrides),
        )

        secret_refs = secrets.map do |s|
          synth.github_actions_environment_secret(
            :"#{repo_name}-#{env_name}-#{s[:name].to_s.downcase}",
            {
              repository:      repo_ref.ref(:name),
              environment:     env.ref(:environment),
              secret_name:     s[:name],
              plaintext_value: s[:plaintext_ref],
            },
          )
        end

        variable_refs = variables.map do |v|
          synth.github_actions_environment_variable(
            :"#{repo_name}-#{env_name}-#{v[:name].to_s.downcase}",
            {
              repository:    repo_ref.ref(:name),
              environment:   env.ref(:environment),
              variable_name: v[:name],
              value:         v[:value].to_s,
            },
          )
        end

        { env: env, secrets: secret_refs, variables: variable_refs }
      end

      # ══════════════════════════════════════════════════════════════
      # Repo-scope Actions secret + variable presets
      # ══════════════════════════════════════════════════════════════

      # Bulk emit repo-scope secrets. `entries` is Array<{name:, plaintext_ref:}>.
      def self.repo_actions_secrets(synth, repo_name:, entries: [])
        _ensure_extended(synth)
        entries.map do |s|
          synth.github_actions_secret(
            :"#{repo_name}-#{s[:name].to_s.downcase}",
            {
              repository:      repo_name,
              secret_name:     s[:name],
              plaintext_value: s[:plaintext_ref],
            },
          )
        end
      end

      # Bulk emit repo-scope variables. `entries` is Array<{name:, value:}>.
      def self.repo_actions_variables(synth, repo_name:, entries: [])
        _ensure_extended(synth)
        entries.map do |v|
          synth.github_actions_variable(
            :"#{repo_name}-#{v[:name].to_s.downcase}",
            {
              repository:    repo_name,
              variable_name: v[:name],
              value:         v[:value].to_s,
            },
          )
        end
      end

      # ══════════════════════════════════════════════════════════════
      # Label presets
      # ══════════════════════════════════════════════════════════════

      # pleme-io standard label set. Every public repo gets these by
      # default unless overridden.
      STANDARD_LABELS = [
        { name: 'bug',           color: 'd73a4a', description: 'Something isn\'t working' },
        { name: 'documentation', color: '0075ca', description: 'Improvements or additions to documentation' },
        { name: 'enhancement',   color: 'a2eeef', description: 'New feature or request' },
        { name: 'good first issue', color: '7057ff', description: 'Good for newcomers' },
        { name: 'help wanted',   color: '008672', description: 'Extra attention is needed' },
        { name: 'security',      color: 'ee0701', description: 'Security-sensitive issue' },
        { name: 'dependencies',  color: '0366d6', description: 'Pull requests that update a dependency' },
      ].freeze

      def self.standard_labels_for(synth, repo_name:, labels: STANDARD_LABELS)
        _ensure_extended(synth)
        labels.map do |l|
          synth.github_issue_label(
            :"#{repo_name}-label-#{l[:name].tr(' ', '-')}",
            {
              repository:  repo_name,
              name:        l[:name],
              color:       l[:color],
              description: l[:description],
            },
          )
        end
      end

      # ══════════════════════════════════════════════════════════════
      # Topic helpers
      # ══════════════════════════════════════════════════════════════

      # Validate a topic set against GitHub's rules. Raises if invalid
      # (empty, uppercase, too long, non-allowed chars, too many).
      # Topics are sorted + deduplicated before returning.
      def self.validate_topics(topics)
        seen = {}
        topics.each do |t|
          raise ArgumentError, "topic must be a String, got #{t.class}" unless t.is_a?(String)
          raise ArgumentError, "topic must be 1–35 chars, got #{t.inspect}" if t.empty? || t.size > 35
          unless t.match?(/\A[a-z0-9-]+\z/)
            raise ArgumentError, "topic #{t.inspect} must be lowercase letters/digits/hyphens only"
          end
          seen[t] = true
        end
        raise ArgumentError, "at most 20 topics allowed, got #{seen.size}" if seen.size > 20
        seen.keys.sort
      end
    end
  end
end
