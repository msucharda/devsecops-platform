@{
    # Each function marked with '# security-check: <name>' must be configured here exactly once.
    # The runner weakens the marked function and requires that the listed tests fail for every mutant.
    # FullName holds Pester full-name wildcard patterns; keep them narrow because each mutant runs them in a fresh process.
    Checks = @(
        @{
            Name = 'development-token-capacity'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = '*Protected development token journal*' })
        }
        @{
            Name = 'development-control-write-http'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenController.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-control-issuance'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenController.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-token-retirement'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenController.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-token-active-installation'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenController.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-control-writer'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentTokenController.Tests.ps1'; FullName = '*' }
                @{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = '*explicit protected writer*' }
            )
        }
        @{
            Name = 'development-control-append'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenController.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-control-journal'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-protocol-object'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-protocol-unique-fields'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-token-context'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-token-journal'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = '*' })
        }
        @{
            Name = 'development-token-key'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = @(
                '*rejects a recovery <Case>*', '*recovers the exact known leaf*'
            ) })
        }
        @{
            Name = 'development-token-value'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = @(
                '*rejects <Case> token values*', '*recovers the exact known leaf*', '*round-trips the maximum*'
            ) })
        }
        @{
            Name = 'development-token-envelope'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = @(
                '*rejects encrypted token <Case>*', '*rejects malformed encrypted token document <Case>*',
                '*rejects a recovery <Case>*', '*recovers the exact known leaf*', '*round-trips the maximum*'
            ) })
        }
        @{
            Name = 'development-token-recovered-digest'
            Tests = @(@{ Path = 'tools/tests/DevelopmentTokenLifecycle.Tests.ps1'; FullName = @(
                '*rejects encrypted token <Case>*', '*recovers the exact known leaf*'
            ) })
        }
        @{
            Name = 'development-state-field-names'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentState.Tests.ps1'; FullName = @(
                    '*publishes an exact root snapshot*', '*noncanonical <Field> JSON field*'
                ) }
            )
        }
        @{
            Name = 'development-state-source'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentState.Tests.ps1'; FullName = @(
                    '*publishes an exact root snapshot*', '*digest*', '*requires a source file*',
                    '*root publication directory*', '*source file itself*', '*overlapping*', '*symbolic-link*'
                ) }
            )
        }
        @{
            Name = 'development-state-publication'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentState.Tests.ps1'; FullName = @(
                    '*publishes an exact root snapshot*', '*recovers publication*',
                    '*preserves an unexpected staging*', '*altered published*', '*second publisher*',
                    '*two real competing processes*'
                ) }
            )
        }
        @{
            Name = 'development-state-attributes'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentState.Tests.ps1'; FullName = @(
                    '*publishes an exact root snapshot*', '*rejects <Case> resource attributes before publication'
                ) }
            )
        }
        @{
            Name = 'development-state-path'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentState.Tests.ps1'; FullName = @(
                    '*publishes an exact root snapshot*', '*symbolic-link*'
                ) }
            )
        }
        @{
            Name = 'development-state-published'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentState.Tests.ps1'; FullName = @(
                    '*recovers publication*', '*altered published*'
                ) }
            )
        }
        @{
            Name = 'development-state-closure'
            Tests = @(
                @{ Path = 'tools/tests/DevelopmentState.Tests.ps1'; FullName = @(
                    '*publishes an exact root snapshot*', '*also supports the resource-free*',
                    '*rejects <Case> state before publication'
                ) }
            )
        }
        @{
            Name = 'development-control-snapshot'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-ruleset'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-prerequisite-artifact'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development protected execution closure*' })
        }
        @{
            Name = 'development-phase-authority'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development protected execution closure*' })
        }
        @{
            Name = 'development-protected-module'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development protected execution closure*' })
        }
        @{
            Name = 'development-protected-execution'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development protected execution closure*' })
        }
        @{
            Name = 'development-control-protection'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-http'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-reference'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-tree'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-file'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-document'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-stability'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = 'Protected development control snapshot*' })
        }
        @{
            Name = 'development-control-context'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = '*Control command*' })
        }
        @{
            Name = 'development-control-designation'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = '*Control command*' })
        }
        @{
            Name = 'development-protected-continuity'
            Tests = @(@{ Path = 'tools/tests/DevelopmentControl.Tests.ps1'; FullName = '*Protected credential boundary*' })
        }
        @{
            Name = 'development-approval-continuity'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development approval continuity*' })
        }
        @{
            Name = 'standard-deployment-development-lock'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development standard-deployment exclusion*' })
        }
        @{
            Name = 'development-candidate-snapshot'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development immutable checkout*' }
                @{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = '*does not hand off credentials for changed working bytes*' })
        }
        @{
            Name = 'development-candidate-approval'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development exact-content approval*' })
        }
        @{
            Name = 'development-candidate-boundary'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development editable boundary*' })
        }
        @{
            Name = 'development-candidate-revision'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development immutable checkout*' })
        }
        @{
            Name = 'development-dispatch-request'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development dispatch authorization*' })
        }
        @{
            Name = 'development-dispatch-context'
            Tests = @(@{ Path = 'tools/tests/DevelopmentCandidate.Tests.ps1'; FullName = '*Development dispatch authorization*' })
        }
        @{
            Name = 'github-repository-target'
            Tests = @(@{ Path = 'tools/tests/GitHubHost.Tests.ps1'; FullName = 'GitHub cloud repository targets*' })
        }
        @{
            Name = 'github-cloud-target'
            Tests = @(@{ Path = 'tools/tests/GitHubHost.Tests.ps1'; FullName = 'GitHub cloud repository targets*' })
        }
        @{
            Name = 'github-worker-lifetime'
            Tests = @(@{ Path = 'tools/tests/GitHubHost.Tests.ps1'; FullName = @('GitHub worker process lifetime*', 'Deadline-bounded GitHub CLI credentials*') })
        }
        @{
            Name = 'github-command-deadline'
            Tests = @(@{ Path = 'tools/tests/GitHubHost.Tests.ps1'; FullName = @('Deadline-bounded GitHub CLI credentials*', 'Host-scoped GitHub CLI credentials*') })
        }
        @{
            Name = 'github-command-process'
            Tests = @(@{ Path = 'tools/tests/GitHubHost.Tests.ps1'; FullName = @('Deadline-bounded GitHub CLI credentials*', 'Host-scoped GitHub CLI credentials*') })
        }
        @{
            Name = 'github-host-credentials'
            Tests = @(@{ Path = 'tools/tests/GitHubHost.Tests.ps1'; FullName = 'Host-scoped GitHub CLI credentials*' })
        }
        @{
            Name = 'pull-request-check-head'
            Tests = @(@{ Path = 'tools/tests/WaitPullRequestChecks.Tests.ps1'; FullName = @('*reports passed and*', '*rejects a successful*') })
        }
        @{
            Name = 'pull-request-check-pagination'
            Tests = @(@{
                Path = 'tools/tests/WaitPullRequestChecks.Tests.ps1'
                FullName = @('*reports passed and*', '*rejects an incomplete*', '*rejects unreadable or inconsistent*', '*reads every page*', '*exits with 3*')
            })
        }
        @{
            Name = 'local-ci-benchmark-output-entry'
            Tests = @(@{
                Path = 'tools/tests/LocalCiBenchmark.Tests.ps1'
                FullName = @('*refuses a reparse-point*', '*measures only the documentation scenario*')
            })
        }
        @{
            Name = 'local-ci-pester-case'
            Tests = @(@{
                Path = 'tools/tests/LocalCiPester.Tests.ps1'
                FullName = @('*accepts the Pester Ignored root variant*', '*accepts an executed inconclusive case*', '*rejects a hidden test*')
            })
        }
        @{
            Name = 'local-ci-pester-result'
            Tests = @(@{
                Path = 'tools/tests/LocalCiPester.Tests.ps1'
                FullName = @('*accepts the Pester Ignored root variant*', '*accepts an executed inconclusive case*', '*fails closed for <Case>*',
                    '*rejects a hidden test*', '*rejects invalid shard metadata*', '*preserves all file suites*',
                    '*rejects a selected file suite*')
            })
        }
        @{
            Name = 'local-ci-step-result'
            Tests = @(@{
                Path = 'tools/tests/LocalCiGate.Unit.Tests.ps1'
                FullName = 'Local CI step result acceptance*'
            })
        }
        @{
            Name = 'local-ci-unix-temp-access'
            Tests = @(@{
                Path = 'tools/tests/PowerShellAnalysisCache.Tests.ps1'
                FullName = 'Local CI Unix private directory access*'
            })
        }
        @{
            Name = 'powershell-analysis-source-binding'
            Tests = @(@{
                Path = 'tools/tests/PowerShellAnalysisCache.Tests.ps1'
                FullName = @('*analyzes a cold file*', '*rejects a file changed during analysis*')
            })
        }
        @{
            Name = 'powershell-analysis-success'
            Tests = @(@{
                Path = 'tools/tests/PowerShellAnalysisCache.Tests.ps1'
                FullName = @('*analyzes a cold file*', '*never caches analyzer warnings*')
            })
        }
        @{
            Name = 'powershell-analysis-cache-entry'
            Tests = @(@{
                Path = 'tools/tests/PowerShellAnalysisCache.Tests.ps1'
                FullName = 'PowerShell analysis cache*'
            })
        }
        @{
            Name = 'teardown-workflow-predicates'
            Kind = 'TeardownWorkflow'
            File = 'tools/Generate-TeardownWorkflow.ps1'
            Tests = @(@{
                Path = 'tools/tests/TeardownWorkflow.Tests.ps1'
                FullName = @(
                    'Teardown workflow generation.destroys <Module> only after every selected dependent and after the owner check'
                    'Teardown workflow generation.destroys only selected phase roots*'
                    'Teardown workflow generation.destroys emu-identity last*'
                    'Teardown workflow generation.passes prerequisite outputs*'
                    'Teardown workflow generation.destroys with apply installation tokens and no PAT'
                    'Teardown workflow generation.reads every state root*'
                    'Teardown identity approval boundary*'
                )
            })
        }
        @{
            Name = 'deployment-apply-completion'
            Tests = @(@{ Path = 'tools/tests/DeploymentSummary.Tests.ps1'; FullName = 'Deployment apply status*' })
        }
        @{
            Name = 'deployment-plan-change-output'
            Tests = @(@{ Path = 'tools/tests/DeploymentSummary.Tests.ps1'; FullName = @('*publishes a complete plan decision*', '*rejects plan change output*') })
        }
        @{
            Name = 'setup-manual-instance-name'
            Tests = @(@{
                Path = 'tools/tests/InstanceSetupManualSteps.Tests.ps1'
                FullName = @('*guides a selected manifest step*', '*rejects a name that is not an exact match*', '*refuses a confirmed record bound to another instance*')
            })
        }
        @{
            Name = 'vendoring-release-marker-preparation'
            Tests = @(@{ Path = 'tools/tests/Vendoring.Tests.ps1'; FullName = @('*prepares a raw release marker*', '*rejects release marker preparation*') })
        }
        @{
            Name = 'vendoring-publish-release-marker'
            Tests = @(@{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*commits the root release marker*', '*rejects a release prepared without its root marker*', '*opens an App PR containing updated files*') })
        }
        @{
            Name = 'deployment-release-marker-file'
            Tests = @(@{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = 'Deployment release preflight*' })
        }
        @{
            Name = 'deployment-release-tree'
            Tests = @(@{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = 'Deployment release preflight*' })
        }
        @{
            Name = 'deployment-release-raw'
            Tests = @(@{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = 'Deployment release preflight*' })
        }
        @{
            Name = 'deployment-release-files'
            Tests = @(@{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = 'Deployment release preflight*' })
        }
        @{
            Name = 'deployment-release-marker'
            Tests = @(@{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = 'Deployment release preflight*' })
        }
        @{
            Name = 'deployment-release-catalog-snapshot'
            Tests = @(@{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = 'Deployment release preflight*' })
        }
        @{
            Name = 'vendoring-publish-catalog-snapshot'
            Tests = @(@{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*catalog snapshot*', '*catalog as a version 2 release receipt*', '*import-time catalog*', '*configured actions organization*') })
        }
        @{
            Name = 'vendoring-catalog-snapshot'
            Tests = @(
                @{ Path = 'tools/tests/DeploymentRelease.Tests.ps1'; FullName = 'Deployment release preflight*' }
                @{ Path = 'tools/tests/Vendoring.Tests.ps1'; FullName = 'Vendored source preparation through the public command*' }
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*rejects catalog snapshot*at the public publisher boundary*', '*rejects array-valued catalog snapshot*at the public publisher boundary*') }
            )
        }
        @{
            Name = 'vendoring-source-receipt'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*rejects array-valued source receipt*before publication*', '*rejects malformed source receipt*before publication*', '*rejects a trailing LF in source receipt*before publication*', '*opens an App PR containing updated files*') }
            )
        }
        @{
            Name = 'token-issuance-revocation'
            Tests = @(@{
                Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'
                FullName = @('Installation token issuance recovery*private intent*', 'Installation token issuance recovery*without HTTP 204*')
            })
        }
        @{
            Name = 'token-issuance-reparse'
            Tests = @(@{
                Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'
                FullName = @('Installation token issuance recovery*private intent*', 'Installation token issuance recovery*reparse-point*')
            })
        }
        @{
            Name = 'token-issuance-ancestor'
            Tests = @(@{
                Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'
                FullName = @('Installation token issuance recovery*private intent*', 'Installation token issuance recovery*state ancestor*')
            })
        }
        @{
            Name = 'legacy-code-security-transition'
            Tests = @(@{ Path = 'tools/tests/ModuleRunner.Tests.ps1'; FullName = @('Legacy Code Security transition identity validation*') })
        }
        @{
            Name = 'code-security-coverage-artifact'
            Tests = @(@{ Path = 'tools/tests/DriftReport.Tests.ps1'; FullName = @('Drift report evaluation*coverage*artifact*', 'Drift report evaluation*early Code Security coverage*') })
        }
        @{
            Name = 'code-security-coverage-identity'
            Tests = @(
                @{ Path = 'tools/tests/CodeSecurityCoverage.Tests.ps1'; FullName = @('Repository Code Security coverage*') }
            )
        }
        @{
            Name = 'code-security-repository-coverage'
            Tests = @(
                @{ Path = 'tools/tests/CodeSecurityCoverage.Tests.ps1'; FullName = @('Repository Code Security coverage*') }
            )
        }
        @{
            Name = 'ruleset-code-security-prerequisite'
            Tests = @(
                @{ Path = 'tools/tests/RulesetCodeSecurity.Tests.ps1'; FullName = @('Ruleset Code Security prerequisite*') }
            )
        }
        @{
            Name = 'github-token-revocation-status'
            Tests = @(@{ Path = 'tools/tests/GitHubTokenRevocation.Tests.ps1'; FullName = 'Job installation token revocation retry*' })
        }
        @{
            Name = 'github-retry-method'
            Tests = @(@{ Path = 'tools/tests/GitHubRetry.Tests.ps1'; FullName = 'GitHub request retry policy*' })
        }
        @{
            Name = 'github-retry-status'
            Tests = @(@{ Path = 'tools/tests/GitHubRetry.Tests.ps1'; FullName = 'GitHub request retry policy*' })
        }
        @{
            Name = 'workflow-uses-reference'
            Tests = @(
                @{ Path = 'tools/tests/WorkflowPreflight.Tests.ps1'; FullName = @('*pinned references', '*rejects <Case> references', '*unsafe local*', '*follows a local composite*', '*repository root as a local action*') }
            )
        }
        @{
            Name = 'workflow-document-shape'
            Tests = @(
                @{ Path = 'tools/tests/WorkflowPreflight.Tests.ps1'; FullName = @('*malformed document*', '*local action shape*', '*local JavaScript runtime*', '*local Docker*', '*Docker image name*', '*regular file*', '*accepts an actions organization*', '*traverses local reusable*', '*job named Values*') }
            )
        }
        @{
            Name = 'workflow-local-target'
            Tests = @(
                @{ Path = 'tools/tests/WorkflowPreflight.Tests.ps1'; FullName = @('*local target*', '*ambiguous local*', '*traverses local reusable*', '*repository root as a local action*') }
            )
        }
        @{
            Name = 'workflow-checkout-revision'
            Tests = @(
                @{ Path = 'tools/tests/WorkflowPreflight.Tests.ps1'; FullName = @('*changed HEAD*', '*revision with different casing*', '*accepts an actions organization*') }
            )
        }
        @{
            Name = 'workflow-repository-root'
            Tests = @(
                @{ Path = 'tools/tests/WorkflowPreflight.Tests.ps1'; FullName = @('*repository root*', '*full HEAD SHA*', '*accepts an actions organization*') }
            )
        }
        @{
            Name = 'workflow-yaml-document'
            Tests = @(
                @{ Path = 'tools/tests/WorkflowPreflight.Tests.ps1'; FullName = @('*malformed document*', '*accepts an actions organization*') }
            )
        }
        @{
            Name = 'workflow-repository-snapshot'
            Tests = @(
                @{ Path = 'tools/tests/WorkflowPreflight.Tests.ps1'; FullName = @('*no live workflows*', '*regular file*', '*traverses local reusable*', '*accepts an actions organization*', '*unreadable Git tree*', '*independently as workflow and local action*') }
            )
        }
        @{
            Name = 'platform-ordinal-string'
            Tests = @(
                @{ Path = 'tools/tests/CanonicalConfiguration.Tests.ps1'; FullName = @('Culture-independent configuration normalization*', 'Ordinal organization scope input boundary*') }
            )
        }
        @{
            Name = 'local-ci-index-visibility'
            Tests = @(@{
                Path = 'tools/tests/LocalCiGate.Unit.Tests.ps1'
                FullName = 'Local CI index visibility*'
            })
        }
        @{
            Name = 'local-ci-lease-inheritance'
            Tests = @(@{
                Path = 'tools/tests/LocalCiConcurrency.Tests.ps1'
                FullName = 'Local CI lease inheritance*'
            })
        }
        @{
            Name = 'local-ci-worker-lifetime'
            Tests = @(@{
                Path = 'tools/tests/LocalCiConcurrency.Tests.ps1'
                FullName = 'Local CI worker lifetime*'
            })
        }
        @{
            Name = 'local-ci-temp-root-scope'
            Tests = @(@{
                Path = 'tools/tests/LocalCiGate.Unit.Tests.ps1'
                FullName = 'Local CI Windows TEMP root scope*'
            })
        }
        @{
            Name = 'local-ci-temp-access'
            Tests = @(@{
                Path = 'tools/tests/LocalCiGate.Unit.Tests.ps1'
                FullName = 'Local CI private TEMP access*'
            })
        }
        @{
            Name = 'local-ci-result-binding'
            Tests = @(
                @{ Path = 'tools/tests/LocalCiGate.Tests.ps1'; FullName = @('Local CI content-bound result*') }
            )
        }
        @{
            Name = 'platform-release-cache'
            Tests = @(
                @{ Path = 'tools/tests/VendoredRuntime.Tests.ps1'; FullName = @('Release cache boundary*') }
            )
        }
        @{
            Name = 'tool-package-sha256'
            Tests = @(
                @{ Path = 'tools/tests/InstallToolDependencies.Tests.ps1'; FullName = @('*Tool dependency installation*') }
            )
        }
        @{
            Name = 'tool-module-payload'
            Tests = @(
                @{ Path = 'tools/tests/InstallToolDependencies.Tests.ps1'; FullName = @('*Tool dependency installation*') }
            )
        }
        @{
            Name = 'organizations-api-pagination'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*Assignment pagination*', '*incomplete assignment listing*') }
            )
        }
        @{
            Name = 'token-app-repository-selection'
            Tests = @(
                @{ Path = 'tools/tests/GitHubAppToken.Tests.ps1'; FullName = @('*Explicit manifest installation selection*', '*issues a read-only module token map with <Selection> repository selection*', '*issues an organization-only module token without repository access*') }
            )
        }
        @{
            Name = 'platform-app-manifest-scope'
            Tests = @(
                @{ Path = 'tools/tests/AppInstallationContract.Tests.ps1'; FullName = @('Manifest App installation selection*') }
            )
        }
        @{
            Name = 'organization-roles-predefined-role'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*reads the predefined role*', '*accepts the documented nullable-role*', '*array masquerading as the <Case> enum*', '*selected role with*', '*required role organization*', '*scalar permission*', '*unsupported role organization*', '*numeric organization owner*', '*role that belongs to another organization*') }
            )
        }
        @{
            Name = 'organization-roles-team-identity'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*reads the predefined role*', '*accepts the documented nullable-role*', '*array masquerading as the <Case> enum*', '*numeric organization owner*', '*numeric team slug*', '*rejects the security team with*', '*security team belonging to another organization*') }
            )
        }
        @{
            Name = 'organization-roles-assignment'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*reads the predefined role*', '*accepts the documented nullable-role*', '*array masquerading as an assignment*', '*numeric team slug*', '*non-object role assignment*', '*missing assignment*', '*documented assignment*', '*enterprise team as the organization team*', '*unreadable team role assignment*', '*duplicate assignments*', '*matches only the team*', '*unrelated*', '*optional assignment*', '*saved team ID*', '*replacement team appearing*', '*saved team after a rename*') }
            )
        }
        @{
            Name = 'organization-roles-state'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*reads the predefined role*', '*accepts the documented nullable-role*', '*unsupported roles wrapper*', '*unreadable role array item*', '*non-object full team*', '*missing or ambiguous security_manager*', '*unreadable roles instead of an array*') }
            )
        }
        @{
            Name = 'organization-roles-team-state'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*reads the predefined role*', '*non-object full team*', '*documented team absence*', '*team lookup*') }
            )
        }
        @{
            Name = 'organization-roles-bound-identity'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*assigns only the managed*', '*accepts a pre-existing assignment*', '*changed stored*', '*removes only the declared*') }
            )
        }
        @{
            Name = 'organization-roles-assignment-result'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*assigns only the managed*', '*accepts a pre-existing assignment*', '*recovers a completed assignment*', '*PUT success response*') }
            )
        }
        @{
            Name = 'organization-roles-removal-result'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRoles.Tests.ps1'; FullName = @('*removes only the declared*', '*removes a pre-existing assignment*', '*recovers a completed removal*', '*DELETE success response*', '*DELETE 404*', '*preserves an unrelated*', '*saved team ID*', '*replacement team appearing*', '*changed stored role before removing*', '*saved team after a rename*', '*replacement created after*', '*team disappearance after DELETE*') }
            )
        }
        @{
            Name = 'organization-roles-input'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationRolePrograms.Tests.ps1'; FullName = @('*returns a complete string map*', '*assigns the bound role*', '*validates the pre-existing identity*', '*rejects a non-object reader input*', '*rejects a single-element array*', '*rejects an invalid reader field*', '*rejects an invalid persisted ID*') }
            )
        }
        @{
            Name = 'deployment-pr-branch'
            Tests = @(
                @{ Path = 'tools/tests/PullRequestAuthorization.Tests.ps1'; FullName = @('*vendoring branch*', '*ordinary branch*', '*unreadable head branch*') }
            )
        }
        @{
            Name = 'bootstrap-environment-bypass'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*main-only vendoring environments*', '*admin bypass confirmation*') }
            )
        }
        @{
            Name = 'action-import-catalog'
            Tests = @(
                @{ Path = 'tools/tests/ActionImport.Tests.ps1'; FullName = @('*derives a catalog target*', '*unlisted upstream*', '*configured canonical upstream*', '*Terraform default catalog*', '*invalid catalog state*') }
            )
        }
        @{
            Name = 'vendoring-upstream-commit'
            Tests = @(
                @{ Path = 'tools/tests/Vendoring.Tests.ps1'; FullName = @('*upstream commit*') }
            )
        }
        @{
            Name = 'vendoring-release-commit'
            Tests = @(
                @{ Path = 'tools/tests/Vendoring.Tests.ps1'; FullName = @('*release pin*', '*upstream commit*') }
            )
        }
        @{
            Name = 'vendoring-release-tag'
            Tests = @(
                @{ Path = 'tools/tests/Vendoring.Tests.ps1'; FullName = @('*checks the annotated release pin tag against the catalog: <Case>') }
            )
        }
        @{
            Name = 'bootstrap-vendoring-contract'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*vendoring App isolation*verifies separate*', '*vendoring App isolation*rejects a vendoring binding*') }
            )
        }
        @{
            Name = 'bootstrap-vendoring-isolation'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*vendoring App isolation*verifies separate*', '*vendoring App isolation*rejects a vendoring binding*') }
            )
        }
        @{
            Name = 'bootstrap-vendoring-environment'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*vendoring App isolation*verifies separate*', '*vendoring App isolation*warns about each*', '*vendoring App isolation*rejects inherited*') }
            )
        }
        @{
            Name = 'module-organization-scope'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationScope.Tests.ps1'; FullName = @('Organization-scoped execution contract*') }
                @{ Path = 'tools/tests/CanonicalConfiguration.Tests.ps1'; FullName = @('Ordinal organization scope input boundary*') }
            )
        }
        @{
            Name = 'module-organization-token'
            Tests = @(
                @{ Path = 'tools/tests/OrganizationScope.Tests.ps1'; FullName = @('Organization token isolation*') }
            )
        }
        @{
            Name = 'organizations-installation-scope'
            Tests = @(
                @{ Path = 'tools/tests/Organizations.Tests.ps1'; FullName = @('*Manifest installation scope*') }
            )
        }
        @{
            Name = 'organizations-installation-selection'
            Tests = @(
                @{ Path = 'tools/tests/Organizations.Tests.ps1'; FullName = @('*App installations*installs the App without repository access*', '*App installations*installs an App on all repositories*', '*App installations*does not reinstall an App*', '*App installations*refuses an existing*', '*App installations*requires all repositories*') }
            )
        }
        @{
            Name = 'vendoring-main-ref'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*invalid target main ref: <Case>*', '*opens an App PR*') }
            )
        }
        @{
            Name = 'vendoring-publish-main'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*remote main moving during*', '*remote main moving before confirming*', '*opens an App PR*', '*unchanged*') }
            )
        }
        @{
            Name = 'vendoring-resume-main'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*resumes an orphaned <ImportKind> import with main changes <Change>*') }
            )
        }
        @{
            Name = 'vendoring-merged-main'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*merged import that main no longer contains: <Case>*', '*unchanged*', '*merged import after changes outside*') }
            )
        }
        @{
            Name = 'vendoring-publish-head'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*changed import branch before PR*', '*opens an App PR*') }
            )
        }
        @{
            Name = 'vendoring-resume-ref'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*invalid resume ref: <Case>*', '*recovers the published branch*') }
            )
        }
        @{
            Name = 'vendoring-pr-lookup'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*malformed or ambiguous PR lookup: <Case>*', '*existing PR has lost its branch*', '*recovers the published branch*', '*ambiguous PR history across bases*', '*retargeted <ImportKind> PR*') }
            )
        }
        @{
            Name = 'vendoring-resume-pr'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*invalid resumed PR: <Case>*', '*invalid App PR author: <Case>*', '*accepts documented nullable PR*', '*recovers the published branch*', '*unchanged*', '*malformed merge timestamp*') }
            )
        }
        @{
            Name = 'vendoring-resume-tree'
            Tests = @(
                @{ Path = 'tools/tests/VendoringPullRequest.Tests.ps1'; FullName = @('*changed content or provenance*', '*recovers the published branch*') }
            )
        }
        @{
            Name = 'release-tag-commit'
            Tests = @(
                @{ Path = 'tools/tests/PlatformRelease.Tests.ps1'; FullName = @('*tag-commit mismatch*', '*annotated tag whose tag object*') }
            )
        }
        @{
            Name = 'release-asset-digest'
            Tests = @(
                @{ Path = 'tools/tests/PlatformRelease.Tests.ps1'; FullName = @('*published release with different content*', '*uploaded asset reports another digest*', '*replaces stale, partial and foreign assets*', '*identical published release*') }
            )
        }
        @{
            Name = 'release-published-state'
            Tests = @(
                @{ Path = 'tools/tests/PlatformRelease.Tests.ps1'; FullName = @('*published release with different content*', '*publish response that does not match*', '*identical published release*') }
            )
        }
        @{
            Name = 'vendoring-attestation-pagination'
            Tests = @(
                @{ Path = 'tools/tests/VendoringSource.Tests.ps1'; FullName = @('*attestation pagination*', '*matching attestation on the next cursor page*', '*follows a Link with combined*', '*cyclic attestation next link*', '*later attestation page 404*') }
            )
        }
        @{
            Name = 'vendoring-commit-on-branch'
            Tests = @(
                @{ Path = 'tools/tests/VendoringSource.Tests.ps1'; FullName = @('*release commit*protected branch*') }
            )
        }
        @{
            Name = 'vendoring-required-attestation'
            Tests = @(
                @{ Path = 'tools/tests/VendoringSource.Tests.ps1'; FullName = @('*required*attestation*', '*required-attestation*', '*resolves the exact tag*') }
            )
        }
        @{
            Name = 'github-app-owner'
            Tests = @(
                @{ Path = 'tools/tests/GitHubAppOwner.Tests.ps1'; FullName = @('*') }
                @{ Path = 'tools/tests/InstanceSetup.Tests.ps1'; FullName = @('*accepts the <Case> owner for a Members-only App*', '*rejects and forgets an App owned by another enterprise*') }
                @{ Path = 'tools/tests/GitHubAppToken.Tests.ps1'; FullName = @('*rejects an invalid enterprise owner*', '*issues a members-only token after verifying enterprise ownership*') }
            )
        }
        @{
            Name = 'bootstrap-request-policy'
            Tests = @(
                @{ Path = 'tools/tests/BootstrapExecutionPolicy.Tests.ps1'; FullName = @('*') }
            )
        }
        @{
            Name = 'setup-app-permission'
            Tests = @(
                @{ Path = 'tools/tests/InstanceSetup.Tests.ps1'; FullName = @('*compares App permission*') }
            )
        }
        @{
            Name = 'token-app-permission'
            Tests = @(
                @{ Path = 'tools/tests/GitHubAppToken.Tests.ps1'; FullName = @('*rejects a drift report App with broader permissions*', '*rejects a drift report App permission level that differs only in case*', '*issues a members-only token after verifying enterprise ownership*') }
            )
        }
        @{
            Name = 'token-issuance-response'
            Tests = @(
                @{ Path = 'tools/tests/GitHubAppToken.Tests.ps1'; FullName = @('*reports unresolved issuance for a <Case> token response*', '*issues a members-only token after verifying enterprise ownership*') }
            )
        }
        @{
            Name = 'token-issuance-location'
            Tests = @(@{ Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'; FullName = @('*refuses to store issuance state*', '*publishes a secret-free private intent*') })
        }
        @{
            Name = 'token-issuance-storage'
            Tests = @(@{ Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'; FullName = @('*existing state directory grants broader access*', '*publishes a secret-free private intent*') })
        }
        @{
            Name = 'token-issuance-pending'
            Tests = @(@{ Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'; FullName = @('*retains uncertainty without a blind retry*', '*blocks a <Case> pending record*', '*publishes a secret-free private intent*') })
        }
        @{
            Name = 'token-issuance-content'
            Tests = @(@{ Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'; FullName = @('*does not discard a pending record changed*', '*publishes a secret-free private intent*') })
        }
        @{
            Name = 'token-issuance-cleanup'
            Tests = @(@{ Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'; FullName = @('*retains uncertainty without a blind retry*', '*retains pending state after an uncertain revocation*', '*clears pending state after known cleanup*') })
        }
        @{
            Name = 'token-issuance-resolution'
            Tests = @(@{ Path = 'tools/tests/GitHubTokenIssuance.Tests.ps1'; FullName = @('*requires explicit operator confirmation for a <Case> pending timestamp*', '*allows manual resolution after the seventy-minute wait*') })
        }
        @{
            Name = 'azure-unconditional-role'
            Tests = @(
                @{ Path = 'tools/tests/Bootstrap.Tests.ps1'; FullName = @('*conditional*state grant*', '*conditional assignment returned by resource GET*') }
            )
        }
        @{
            Name = 'bootstrap-external-path'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*rejects inventory inside the running source checkout*', '*accepts the Azure script result object*') }
            )
        }
        @{
            Name = 'bootstrap-upgrade-nochanges'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*refuses a no-change inventory upgrade before any GitHub request') }
            )
        }
        @{
            Name = 'bootstrap-inventory-upgrade-pair'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*isolated upgrade guards*isolated release transition*') }
            )
        }
        @{
            Name = 'bootstrap-main-commit-reference'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*upgrades initialized historical inventory only after protected main proves the current release', '*rejects an invalid main reference <ReferenceCase> before reading protected files', '*rejects an invalid final NoChanges reference: <Case>') }
            )
        }
        @{
            Name = 'bootstrap-main-commit-tree'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*upgrades initialized historical inventory only after protected main proves the current release', '*rejects pinned commit <CommitCase> before reconciliation') }
            )
        }
        @{
            Name = 'bootstrap-main-protected-tree'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*accepts regular protected files with mode <FileMode>', '*rejects a dereferenced symlink at <ProtectedPath> before reconciliation (NoChanges=<ReadOnly>)', '*rejects pinned tree <TreeCase> before reconciliation', '*rejects protected tree entry <EntryCase> at <ProtectedPath> before reconciliation') }
            )
        }
        @{
            Name = 'bootstrap-main-content-file'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*upgrades initialized historical inventory only after protected main proves the current release', '*rejects protected content variant <ContentVariant> before reconciliation', '*rejects protected content <ContentCase> before reconciliation') }
            )
        }
        @{
            Name = 'bootstrap-upgrade-inventory-state'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*isolated upgrade guards*inventory*') }
            )
        }
        @{
            Name = 'bootstrap-upgrade-main-protection'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*isolated upgrade guards*protection*', '*isolated upgrade guards*team*') }
            )
        }
        @{
            Name = 'bootstrap-upgrade-main-stability'
            Tests = @(
                @{ Path = 'tools/tests/GitHubBootstrap.Tests.ps1'; FullName = @('*stops before an Azure write when protected main moves after preflight', '*keeps the previous inventory version when protected main moves during provisioning', '*rejects case-only movement of protected main before reconciliation') }
            )
        }
        @{
            Name = 'acceptance-run-evidence'
            Tests = @(
                @{ Path = 'tools/tests/AcceptanceRunEvidence.Tests.ps1'; FullName = @('*') }
            )
        }
        @{
            Name = 'drift-issue-state'
            Tests = @(
                @{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*opens a new drift issue*', '*updates the single open drift issue*', '*fails closed when the created response*', '*fails closed when the update response*', '*comments on the clean result*', '*rejects a close response*', '*rejects an unreadable matching issue*') }
            )
        }
        @{
            Name = 'drift-clean-comment'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*reuses a clean comment*', '*does not reuse a comment when*', '*leaves recovery ambiguous*') })
        }
        @{
            Name = 'drift-created-comment'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*comments on the clean result*', '*rejects a created clean comment*', '*accepts the documented null author*') })
        }
        @{
            Name = 'drift-run-evidence'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*rejects unreadable clean-run evidence*', '*leaves a legacy issue open*', '*uses the existing read-only token*') })
        }
        @{
            Name = 'drift-clean-evidence'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*rejects unreadable clean-run evidence*', '*rejects stale clean evidence*', '*rejects a last drift report*', '*uses the existing read-only token*', '*rejects an invalid current workflow context*', '*closes matching reports from a custom workflow*') })
        }
        @{
            Name = 'drift-current-main'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*does not close when the main reference*', '*rejects an all-jobs rerun*', '*requires a contents token*', '*uses the existing read-only token*') })
        }
        @{
            Name = 'drift-report-order'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*does not downgrade the last drift evidence*', '*accepts a current correlated drift update*', '*updates the single open drift issue*') })
        }
        @{
            Name = 'drift-organization-result'
            Tests = @(@{ Path = 'tools/tests/OrganizationDrift.Tests.ps1'; FullName = @('Per-organization drift completeness*') })
        }
        @{
            Name = 'drift-need-string'
            Tests = @(@{ Path = 'tools/tests/DriftReport.Tests.ps1'; FullName = @('*refuses array-valued job evidence*', '*records the workflow identity and counter*') })
        }
        @{
            Name = 'drift-collection'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*opens a new drift issue*', '*comments on the clean result*', '*leaves the issue open when*', '*rejects unreadable closed-issue lists*') })
        }
        @{
            Name = 'drift-resolved-report'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*Resolved report recovery*') })
        }
        @{
            Name = 'drift-issue-author'
            Tests = @(@{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('Drift issue publication*') })
        }
        @{
            Name = 'catalog-repository-adoptable'
            Tests = @(
                @{ Path = 'tools/tests/ActionsCatalog.Tests.ps1'; FullName = @('*Test-CatalogRepositoryAdoptable*', '*refuses an existing repository that*', '*refuses a new repository that GitHub created*') }
            )
        }
        @{
            Name = 'catalog-approval-rule'
            Tests = @(
                @{ Path = 'tools/tests/ActionsCatalog.Tests.ps1'; FullName = @('*Test-CatalogApprovalRule*') }
            )
        }
        @{
            Name = 'catalog-team-push'
            Tests = @(
                @{
                    Path = 'tools/tests/ActionsCatalog.Tests.ps1'
                    FullName = @(
                        '*creates the internal repository, opens it to the enterprise, grants the team push*'
                        '*grants push to a team that has only*', '*keeps a team with*', '*security team does not exist*'
                        '*fails closed on a security team reply*', '*fails closed on a team permission reply*'
                    )
                }
            )
        }
        @{
            Name = 'catalog-release-commit'
            Tests = @(
                @{ Path = 'tools/tests/ActionsCatalog.Tests.ps1'; FullName = @('*New-CatalogReleaseTag*') }
            )
        }
        @{
            Name = 'catalog-state-violation'
            Tests = @(
                @{ Path = 'tools/tests/ActionsCatalog.Tests.ps1'; FullName = @('*Get-CatalogStateViolation*') }
            )
        }
        @{
            Name = 'actions-policy-reset-conflict'
            Tests = @(
                @{ Path = 'tools/tests/ActionsPolicy.Tests.ps1'; FullName = @('*Set-ActionsPolicy*') }
            )
        }
        @{
            Name = 'actions-policy-state'
            Tests = @(
                @{ Path = 'tools/tests/ActionsPolicy.Tests.ps1'; FullName = @('*Get-ActionsPolicyStateViolation*') }
            )
        }
        @{
            Name = 'merge-gate-read-only'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*read-only guard*', '*calls only read-only API requests*') }
            )
        }
        @{
            Name = 'merge-gate-pr-state'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G1 state*') }
            )
        }
        @{
            Name = 'merge-gate-draft'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G2 isDraft*') }
            )
        }
        @{
            Name = 'merge-gate-head-pin'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G3 expected head*') }
            )
        }
        @{
            Name = 'merge-gate-run-state'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G4 run state*') }
            )
        }
        @{
            Name = 'merge-gate-copilot-run'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G4 recognizes the Copilot run*', '*G4 <Case> -> <Expected>') }
            )
        }
        @{
            Name = 'merge-gate-ci-checks'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G4 <Case> -> <Expected>') }
            )
        }
        @{
            Name = 'merge-gate-required-integration'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G4 integration*', '*G4 rejects a required context reported by another integration*', '*G4 <Case> -> <Expected>') }
            )
        }
        @{
            Name = 'merge-gate-review-threads'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G5 thread*') }
            )
        }
        @{
            Name = 'merge-gate-copilot-author'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G6 counts a review*') }
            )
        }
        @{
            Name = 'merge-gate-copilot-review'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G6 <Case> -> <Expected>') }
            )
        }
        @{
            Name = 'merge-gate-mergeability'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G7 mergeable*', '*G7 fails a merge queue*') }
            )
        }
        @{
            Name = 'merge-gate-behind-base'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G8 behind*') }
            )
        }
        @{
            Name = 'merge-gate-empty-section'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G9 treats the section*') }
            )
        }
        @{
            Name = 'merge-gate-open-questions'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G9 body*') }
            )
        }
        @{
            Name = 'merge-gate-decision-authors'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G9 author*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-path'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 treats*', '*G10 classifies*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-direct-path'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 pinned trees through CLI reject a rename with*', '*G10 CLI derives a benign rename*', '*G10 handles*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-content'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 rejects*content*', '*G10 rejects*API*', '*G10 ignores*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-tree'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 pinned trees*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-regular-entry'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 pinned trees through CLI allow acknowledgement*', '*G10 pinned trees through CLI retain a rename*', '*G10 pinned trees through CLI reject a rename from*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-merge-base'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 merge base*', '*G10 pinned trees through CLI do not use a base-only*', '*G10 pinned trees through CLI ignore a base-only*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-file-coverage'
            Tests = @(
                @{
                    Path = 'tools/tests/MergeGate.Tests.ps1'
                    # The complete CLI matrix runs in Pester; mutation runs retain the relevant base-tip regressions.
                    FullName = @(
                        '*G10 pinned trees reject*'
                        '*G10 pinned trees preserve*'
                        '*G10 pinned trees reuse*'
                        '*G10 pinned trees repair*'
                        '*G10 pinned trees do not pair*'
                        '*G10 pinned trees consume*'
                        '*G10 pinned trees validate*'
                        '*G10 pinned trees ignore*'
                        '*G10 pinned trees handle*'
                        '*G10 pinned trees detect*'
                        '*G10 pinned trees never pair*'
                        '*G10 pinned trees evaluate*'
                        '*G10 pinned trees resolve*'
                        '*G10 pinned trees through CLI reject reactivation*'
                        '*G10 pinned trees through CLI require acknowledgement when main changed*'
                        '*G10 pinned trees through CLI retain a rename*'
                        '*G10 pinned trees through CLI reject a rename from*'
                        '*G10 handles*'
                    )
                }
            )
        }
        @{
            Name = 'merge-gate-workflow-settings'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 compares*', '*G10 ignores*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-yaml'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 fails closed for*', '*G10 ignores*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-projection'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('Merge gate structural G10*') }
            )
        }
        @{
            Name = 'merge-gate-workflow-comparison'
            Tests = @(
                @{
                    Path = 'tools/tests/MergeGate.Tests.ps1'
                    FullName = @(
                        '*G10 compares*'
                        '*G10 ignores*'
                        '*G10 handles*'
                        '*G10 rejects*file list*'
                        '*G10 pinned trees preserve a rename snapshot error*'
                        '*G10 pinned trees do not pair different sensitive rename projections*'
                        '*G10 pinned trees consume each matching rename source at most once*'
                        '*G10 pinned trees never pair an opaque rename*'
                    )
                }
            )
        }
        @{
            Name = 'merge-gate-workflow-changes'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 finding*') }
            )
        }
        @{
            Name = 'merge-gate-verdict'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*verdict of*') }
            )
        }
        @{
            Name = 'merge-gate-merge-allowed'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*allows a merge only for a pass*') }
            )
        }
        @{
            Name = 'merge-gate-post-merge'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*verifies the merge*') }
            )
        }
    )

    # A surviving mutant fails the run unless it is listed here with a reason and an issue or pull request link.
    # An exception that matches no mutant, or whose mutant is killed, also fails the run.
    Exceptions = @(
        @{
            Mutant = 'Assert-DevelopmentStateAttributes: operator ''-cnotmatch'' -> -inotmatch in ''$Attributes[''id''] -cnotmatch ''^[1-9][0-9]{0,17}\z''''#1'
            Reason = 'Equivalent mutant: the numeric ID pattern contains only decimal digits and anchors, which have no letter case.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentStateAttributes: operator ''-cne'' -> -ine in ''[string] $response[''id''] -cne $Attributes[''id'']''#1'
            Reason = 'Equivalent mutant: the response ID is a validated integer and the state ID is a validated decimal string; neither representation contains letters.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentPublishedSnapshot: operator ''-cne'' -> -ine in ''(Get-FileHash -LiteralPath (Join-Path $Directory $StateName)).Hash.ToLowerInvariant() -cne $Digest''#1'
            Reason = 'Equivalent mutant: this internal comparison receives only the lowercase digest computed by Read-DevelopmentSnapshotSource and a lowercase computed file digest.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Test-DevelopmentControlRuleset: operator ''-cne'' -> -ine in ''$Ruleset[''source_type''] -cne ''Enterprise''''#1'
            Reason = 'Equivalent mutant: the preceding exact documented-enum guard already excludes every case variant of Enterprise.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Test-DevelopmentControlRuleset: operand ''$Ruleset[''rules''] -isnot [Collections.IList]'' -> $false#1'
            Reason = 'Equivalent mutant for JSON responses: a non-list rules value cannot contain both scalar update and deletion rules; the final two-rule requirement still rejects it.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Get-DevelopmentControlProtectionId: condition ''-not $updates.Overlaps($deletions)'' -> $false#1'
            Reason = 'Equivalent mutant: without overlap this function returns no IDs; the marked snapshot guard then rejects the absence of a verified enterprise ruleset before returning state.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentProtectedExecution: operand ''$Baseline.get_Keys() -cnotcontains $path'' -> $false#1'
            Reason = 'Equivalent mutant: verified snapshots contain only nonempty mode:SHA256 strings. An absent baseline entry cannot equal the candidate entry, so the hash comparison still rejects every added protected path.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentProtectedExecution: operand ''$Candidate.get_Keys() -cnotcontains $path'' -> $false#1'
            Reason = 'Equivalent mutant: verified snapshots contain only nonempty mode:SHA256 strings. An absent candidate entry cannot equal the baseline entry, so the hash comparison still rejects every deleted protected path.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentProtectedExecution: operator ''-cnotcontains'' -> -inotcontains in ''$Baseline.get_Keys() -cnotcontains $path''#1'
            Reason = 'Equivalent mutant: the ordinal path union visits both spellings of a case-only rename and the remaining exact candidate membership guard rejects the old spelling.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentProtectedExecution: operator ''-cnotcontains'' -> -inotcontains in ''$Candidate.get_Keys() -cnotcontains $path''#1'
            Reason = 'Equivalent mutant: the ordinal path union visits both spellings of a case-only rename and the remaining exact baseline membership guard rejects the new spelling.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentProtectedExecution: operator ''-cne'' -> -ine in ''$Baseline[$path] -cne $Candidate[$path]''#1'
            Reason = 'Equivalent mutant: snapshot values consist only of numeric Git modes and lowercase SHA256 text, so case-insensitive comparison accepts no different valid value.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentControlStability: operator ''-cne'' -> -ine in ''$Before -cne $After''#1'
            Reason = 'Equivalent mutant: both revisions pass the lowercase full-SHA discriminator before this comparison.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Get-DevelopmentControlProtectionId: condition ''$Rules -isnot [Collections.IList]'' -> $false#1'
            Reason = 'Equivalent mutant: every qualifying rule has a scalar string type and can be either update or deletion, never both. A non-list singleton cannot satisfy the final overlap requirement.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentPhaseAuthority: operator ''-ccontains'' -> -icontains in ''$protected -ccontains $name''#1'
            Reason = 'Equivalent mutant: the instance and module schemas constrain every credential module name to lowercase before this check.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Get-DevelopmentCandidateSnapshot: operator ''-cne'' -> -ine in ''(Invoke-DevelopmentGit $root @(''hash-object'', ''--no-filters'', ''--'', $relative)) -cne $blob''#1'
            Reason = 'Equivalent mutant: both object IDs are produced by Git as lowercase hexadecimal; this comparison does not compare caller-supplied identity text.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentDispatchRequest: operator ''-cne'' -> -ine in ''$ApiUrl.TrimEnd(''/'') -cne "https://api.$($address.DnsSafeHost)"''#1'
            Reason = 'Equivalent mutant: the only additional strings differ in HTTPS scheme or DNS hostname casing, which identifies the same authenticated origin; paths, ports, credentials, query and fragment remain rejected.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentDispatchRequest: operator ''-cne'' -> -ine in ''$address.Scheme -cne ''https''''#1'
            Reason = 'Equivalent mutant: System.Uri normalizes the Scheme property to lowercase before this comparison.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentDispatchRequest: operator ''-cnotmatch'' -> -inotmatch in ''$PullRequest -cnotmatch ''^[1-9][0-9]*\z''''#1'
            Reason = 'Equivalent mutant: this pattern contains only decimal digits and anchors, which have no letter case.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentDispatchRequest: operator ''-cnotmatch'' -> -inotmatch in ''$Repository -cnotmatch ''^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+\z''''#1'
            Reason = 'Equivalent mutant: both uppercase and lowercase ASCII letters are explicitly included in every letter class.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentDispatchContext: operator ''-cne'' -> -ine in ''[string] $Pull[''number''] -cne $PullRequest''#1'
            Reason = 'Equivalent mutant: the approved pull request identifier is constrained to decimal digits, whose equality has no letter case.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentCandidateBoundary: operand ''$Baseline.get_Keys() -ccontains $path'' -> $true#1'
            Reason = 'Equivalent mutant: verified snapshots contain only nonempty mode:SHA256 strings. An absent baseline entry cannot equal the candidate entry, so the remaining equality still detects every added path.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentCandidateBoundary: operand ''$Candidate.get_Keys() -ccontains $path'' -> $true#1'
            Reason = 'Equivalent mutant: verified snapshots contain only nonempty mode:SHA256 strings. An absent candidate entry cannot equal the baseline entry, so the remaining equality still detects every deleted path.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentCandidateBoundary: operator ''-ccontains'' -> -icontains in ''$Baseline.get_Keys() -ccontains $path''#1'
            Reason = 'Equivalent mutant: the case-sensitive union visits both spellings of a case-only rename; the unchanged candidate membership guard rejects the old spelling, so no rename is hidden.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentCandidateBoundary: operator ''-ccontains'' -> -icontains in ''$Candidate.get_Keys() -ccontains $path''#1'
            Reason = 'Equivalent mutant: the case-sensitive union visits both spellings of a case-only rename; the unchanged baseline membership guard rejects the new spelling, so no rename is hidden.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Assert-DevelopmentCandidateBoundary: operator ''-ceq'' -> -ieq in ''$Baseline[$path] -ceq $Candidate[$path]''#1'
            Reason = 'Equivalent mutant: verified snapshot values contain only a numeric Git mode and lowercase SHA256 text; case-insensitive equality admits no different valid hash or mode.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/259'
        }
        @{
            Mutant = 'Test-SecurityManagerAssignment: operator ''-ceq'' -> -ieq in ''$entry[''type''] -ceq ''enterprise''''#1'
            Reason = 'Equivalent mutant: the preceding scalar-string and case-sensitive enum guards permit only the exact values organization and enterprise.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/105'
        }
        @{
            Mutant = 'Test-SecurityManagerAssignment: operator ''-cin'' -> -iin in ''$matched[0][''assignment''] -cin @(''direct'', ''mixed'')''#1'
            Reason = 'Equivalent mutant: each matched assignment has already passed the scalar-string and case-sensitive direct/indirect/mixed enum guards.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/105'
        }
        @{
            Mutant = 'Get-OrganizationAppScopeViolation: operator ''-cnotmatch'' -> -inotmatch in ''$clientId -cnotmatch ''^[A-Za-z0-9][A-Za-z0-9.]{0,63}\z''''#1'
            Reason = 'Equivalent mutant: the client ID pattern explicitly includes both uppercase and lowercase ASCII letters, digits and dots. Case-insensitive matching accepts no additional value.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/105'
        }
        @{
            Mutant = 'Assert-OrganizationInstallationSelection: operator ''-cne'' -> -ine in ''$Installation[''repository_selection''] -cne ''all''''#1'
            Reason = 'Equivalent mutant: every caller supplies an installation returned by Get-OrganizationAppInstallation, which rejects any selection other than the exact lowercase values all and selected before this comparison.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/105'
        }
        @{
            Mutant = 'Assert-OrganizationInstallationSelection: operator ''-cne'' -> -ine in ''$Installation[''repository_selection''] -cne ''selected''''#1'
            Reason = 'Equivalent mutant: every caller supplies an installation returned by Get-OrganizationAppInstallation, which rejects any selection other than the exact lowercase values all and selected before this comparison.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/105'
        }
        @{
            Mutant = 'Assert-VendoringPublishMain: operator ''-cne'' -> -ine in ''(Get-VendoringMainRef) -cne $mainSha''#1'
            Reason = 'Equivalent mutant: both the captured SHA and every subsequent SHA come from Get-VendoringMainRef, whose case-sensitive pattern requires exactly 40 lowercase hexadecimal characters. Case-insensitive comparison cannot accept a different value in that domain.'
            Issue = 'https://github.com/msucharda/devsecops-platform/pull/88'
        }
        @{
            Mutant = 'Assert-IssueState: operator ''-cnotmatch'' -> -inotmatch in ''[string] $Issue[''number''] -cnotmatch ''^[1-9][0-9]*$''''#1'
            Reason = 'Equivalent mutant: the pattern contains only digit classes, and no character matches a digit class case-insensitively but not case-sensitively.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/57'
        }
        @{
            Mutant = 'Assert-IssueState: operator ''-cne'' -> -ine in ''[string] $Issue[''number''] -cne $ExpectedNumber''#1'
            Reason = 'Equivalent mutant: the same condition first requires the issue number to be a decimal number, which has no case.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/57'
        }
        @{
            Mutant = 'Assert-CreatedComment: operator ''-cnotmatch'' -> -inotmatch in ''[string] $Comment[''id''] -cnotmatch ''^[1-9][0-9]*$''''#1'
            Reason = 'Equivalent mutant: the pattern contains only decimal digits and anchors, which have no case.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/200'
        }
        @{
            Mutant = 'Test-CodeSecurityArtifactId: operand ''$Value -is [string]'' -> $true#1'
            Reason = 'Equivalent mutant: the only caller passes Get-NeedValue, which returns only scalar strings or null. Null cannot match the positive decimal ID pattern, so removing this type guard admits no additional input.'
            Issue = 'https://github.com/msucharda/devsecops-platform/pull/212'
        }
        @{
            Mutant = 'Test-SetupAcceptanceRunEvidence: operator ''-cne'' -> -ine in ''[string] $record[''runId''] -cne [string] $Run[''id'']''#1'
            Reason = 'Equivalent mutant: the GitHub workflow run ID is an integer, so a case-insensitive comparison accepts no other value.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/57'
        }
        @{
            Mutant = 'Test-SetupAcceptanceRunEvidence: operator ''-cne'' -> -ine in ''[string] $record[''runAttempt''] -cne [string] $Run[''run_attempt'']''#1'
            Reason = 'Equivalent mutant: the GitHub workflow run attempt is an integer, so a case-insensitive comparison accepts no other value.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/57'
        }
    )
}
