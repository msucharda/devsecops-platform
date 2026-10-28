@{
    # Each function marked with '# security-check: <name>' must be configured here exactly once.
    # The runner weakens the marked function and requires that the listed tests fail for every mutant.
    # FullName holds Pester full-name wildcard patterns; keep them narrow because each mutant runs them in a fresh process.
    Checks = @(
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
            Name = 'acceptance-run-evidence'
            Tests = @(
                @{ Path = 'tools/tests/AcceptanceRunEvidence.Tests.ps1'; FullName = @('*') }
            )
        }
        @{
            Name = 'drift-open-issue'
            Tests = @(
                @{ Path = 'tools/tests/DriftIssue.Tests.ps1'; FullName = @('*opens a new drift issue*', '*updates the single open drift issue*', '*fails closed when the created response*', '*fails closed when the update response*') }
            )
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
            Name = 'merge-gate-workflow-content'
            Tests = @(
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 rejects*content*', '*G10 rejects*API*', '*G10 ignores*') }
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
                @{ Path = 'tools/tests/MergeGate.Tests.ps1'; FullName = @('*G10 compares*', '*G10 ignores*', '*G10 handles*', '*G10 rejects*file list*') }
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
            Mutant = 'Assert-OpenIssue: operator ''-cnotmatch'' -> -inotmatch in ''[string] $Issue[''number''] -cnotmatch ''^[1-9][0-9]*$''''#1'
            Reason = 'Equivalent mutant: the pattern contains only digit classes, and no character matches a digit class case-insensitively but not case-sensitively.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/57'
        }
        @{
            Mutant = 'Assert-OpenIssue: operator ''-cne'' -> -ine in ''[string] $Issue[''number''] -cne $ExpectedNumber''#1'
            Reason = 'Equivalent mutant: the same condition first requires the issue number to be a decimal number, which has no case.'
            Issue = 'https://github.com/msucharda/devsecops-platform/issues/57'
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
