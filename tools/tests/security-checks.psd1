@{
    # Each function marked with '# security-check: <name>' must be configured here exactly once.
    # The runner weakens the marked function and requires that the listed tests fail for every mutant.
    # FullName holds Pester full-name wildcard patterns; keep them narrow because each mutant runs them in a fresh process.
    Checks = @(
        @{
            Name = 'deployment-pr-branch'
            Tests = @(
                @{ Path = 'tools/tests/PullRequestAuthorization.Tests.ps1'; FullName = @('*vendoring branch*', '*ordinary branch*', '*unreadable head branch*') }
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
    )

    # A surviving mutant fails the run unless it is listed here with a reason and an issue or pull request link.
    # An exception that matches no mutant, or whose mutant is killed, also fails the run.
    Exceptions = @(
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
