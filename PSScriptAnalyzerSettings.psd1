# PSScriptAnalyzer configuration for Daily IT Tools.
#
# These are standalone interactive scripts, not a published module, so a few of
# the default rules do not apply. Everything else stays on, including the
# security rules.
@{
    # Information-level findings are style chatter (positional parameters in a
    # test file's own assertion helper, and similar). They buried the actual
    # test output in the CI log, so only real findings are reported.
    Severity = @('Warning', 'Error')

    ExcludeRules = @(
        # These tools talk to the person sitting in front of them. Console output
        # is the point, and Write-Output would pollute the return values that
        # functions like New-Mapping and Get-DriveLetterItems rely on.
        'PSAvoidUsingWriteHost',

        # Get-DriveLetterItems and friends genuinely return collections. The
        # plural reads correctly and these are not exported cmdlets.
        'PSUseSingularNouns',

        # -WhatIf / -Confirm plumbing on internal helpers of a GUI tool adds
        # surface area with no caller that would ever pass those switches. The
        # window already confirms before it replaces or disconnects a drive.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
