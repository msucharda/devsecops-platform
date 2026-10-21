@{
    # Each function marked with '# security-check: <name>' must be configured here exactly once.
    # The runner weakens the marked function and requires that the listed tests fail for every mutant.
    # FullName holds Pester full-name wildcard patterns; keep them narrow because each mutant runs them in a fresh process.
    Checks = @(
        @{
            Name = 'github-app-owner'
            Tests = @(
                @{ Path = 'tools/tests/GitHubAppOwner.Tests.ps1'; FullName = @('*') }
                @{ Path = 'tools/tests/InstanceSetup.Tests.ps1'; FullName = @('*accepts the observed enterprise owner login*') }
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
    )

    # A surviving mutant fails the run unless it is listed here with a reason and an issue or pull request link.
    # An exception that matches no mutant, or whose mutant is killed, also fails the run.
    Exceptions = @(
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
