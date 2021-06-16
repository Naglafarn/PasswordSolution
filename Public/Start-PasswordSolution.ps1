﻿function Start-PasswordSolution {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary] $EmailParameters,
        [System.Collections.IDictionary] $ConfigurationParameters,
        [string] $OverwriteEmailProperty,
        [System.Collections.IDictionary] $UserSection,
        [System.Collections.IDictionary] $ManagerSection,
        [System.Collections.IDictionary] $AdminSection,
        [Array] $Rules,
        [scriptblock] $TemplatePreExpiry,
        [string] $TemplatePreExpirySubject,
        [scriptblock] $TemplatePostExpiry,
        [string] $TemplatePostExpirySubject,
        [scriptblock] $TemplateManager,
        [string] $TemplateManagerSubject,
        [scriptblock] $TemplateManagerMissing,
        [string] $TemplateManagerMissingSubject,
        [scriptblock] $TemplateManagerDisabled,
        [string] $TemplateManagerDisabledSubject,
        [scriptblock] $TemplateManagerNoEmail,
        [string] $TemplateManagerNoEmailSubject,
        [scriptblock] $TemplateManagerNotCompliant,
        [string] $TemplateManagerNotCompliantSubject,
        [System.Collections.IDictionary] $DisplayConsole,
        [System.Collections.IDictionary] $HTMLOptions,
        [string] $FilePath
    )

    if ($null -eq $DisplayConsole) {
        $WriteParameters = @{
            ShowTime   = $true
            LogFile    = ""
            TimeFormat = "yyyy-MM-dd HH:mm:ss"
        }
    } else {
        $WriteParameters = $DisplayConsole
    }


    $Summary = [ordered] @{}
    $Summary['Notify'] = [ordered] @{}
    $Summary['NotifyManager'] = [ordered] @{}
    $Summary['Rules'] = [ordered] @{}


    $CachedUsers = Find-Password -AsHashTable -OverwriteEmailProperty $OverwriteEmailProperty
    foreach ($Rule in $Rules) {
        # Go for each rule and check if the user is in any of those rules
        if ($Rule.Enable -eq $true) {
            # Lets create summary for the rule
            if (-not $Summary['Rules'][$Rule.Name] ) {
                $Summary['Rules'][$Rule.Name] = [ordered] @{}
            }
            Write-Color @WriteParameters -Text "[i] Processing rule ", $Rule.Name -Color White, Yellow, White, Yellow, White, Yellow, White
            foreach ($User in $CachedUsers.Values) {
                if ($User.Enabled -eq $false) {
                    # We don't want to have disabled users
                    continue
                }
                if ($Rule.LimitOU.Count -gt 0) {
                    # Rule defined that only user withi specific OU has to be found
                    $FoundOU = $false
                    foreach ($OU in $Rule.LimitOU) {
                        if ($User.OrganizationalUnit -like $OU) {
                            $FoundOU = $true
                            break
                        }
                    }
                    if (-not $FoundOU) {
                        continue
                    }
                }
                if ($Rule.LimitGroup.Count -gt 0) {
                    # Rule defined that only user withi specific group has to be found
                    $FoundGroup = $false
                    foreach ($Group in $Rule.LimitGroup) {
                        if ($User.MemberOf -contains $Group) {
                            $FoundGroup = $true
                            break
                        }
                    }
                    if (-not $FoundGroup) {
                        continue
                    }
                }

                if ($Summary['Notify'][$User.DistinguishedName]) {
                    # User already exists in the notifications - rules are overlapping, we only take the first one
                    continue
                }

                # Lets find users that expire
                if ($User.DaysToExpire -in $Rule.Reminders) {
                    $Summary['Notify'][$User.DistinguishedName] = [ordered] @{
                        User = $User
                        Rule = $Rule
                    }
                    $Summary['Rules'][$Rule.Name][$User.DistinguishedName] = [ordered] @{
                        User = $User
                        Rule = $Rule
                    }

                    if ($Rule.SendToManager -and $Rule.SendToManager.Enable -eq $true) {
                        if ($User.ManagerStatus -eq 'Enabled' -and $User.ManagerEmail -like "*@*") {
                            # Manager is enabled and has an email
                            $Splat = [ordered] @{
                                SummaryDictionary = $Summary['NotifyManager']
                                Type              = 'ManagerDefault'
                                Key               = $User.ManagerDN
                                User              = $User
                                Rule              = $Rule
                                Enabled           = $true
                            }
                            Add-ManagerInformation @Splat
                        } else {
                            # Not compliant (missing, disabled, no email), covers all the below options
                            $Splat = [ordered] @{
                                SummaryDictionary = $Summary['NotifyManager']
                                Type              = 'ManagerNotCompliant'
                                Key               = $Rule.SendToManager.ManagerNotCompliant.Email
                                User              = $User
                                Rule              = $Rule
                                Enabled           = $Rule.SendToManager.ManagerNotCompliant.Enable
                            }
                            Add-ManagerInformation @Splat

                            if ($User.ManagerStatus -eq 'Enabled') {
                                # Manager is enabled but missing email
                                $Splat = [ordered] @{
                                    SummaryDictionary = $Summary['NotifyManager']
                                    Type              = 'ManagerMissingEmail'
                                    Key               = $Rule.SendToManager.ManagerMissingEmail.Email
                                    User              = $User
                                    Rule              = $Rule
                                    Enabled           = $Rule.SendToManager.ManagerMissingEmail.Enable
                                }
                                Add-ManagerInformation @Splat
                            } elseif ($User.ManagerStatus -eq 'Disabled') {
                                # Manager is disabled, regardless if he/she has email
                                $Splat = [ordered] @{
                                    SummaryDictionary = $Summary['NotifyManager']
                                    Type              = 'ManagerDisabled'
                                    Key               = $Rule.SendToManager.ManagerDisabled.Email
                                    User              = $User
                                    Rule              = $Rule
                                    Enabled           = $Rule.SendToManager.ManagerDisabled.Enable
                                }
                                Add-ManagerInformation @Splat
                                # }
                            } else {
                                # Manager is missing
                                $Splat = [ordered] @{
                                    SummaryDictionary = $Summary['NotifyManager']
                                    Type              = 'ManagerMissing'
                                    Key               = $Rule.SendToManager.ManagerMissing.Email
                                    User              = $User
                                    Rule              = $Rule
                                    Enabled           = $Rule.SendToManager.ManagerMissing.Enable
                                }
                                Add-ManagerInformation @Splat
                            }
                        }
                    }
                } else {

                }
            }
        }
    }

    if ($UserSection.Enable) {
        Write-Color @WriteParameters -Text "[i] Sending notifications to users " -Color White, Yellow, White, Yellow, White, Yellow, White
        $CountUsers = 0
        [Array] $SummaryUsersEmails = foreach ($Notify in $Summary['Notify'].Values) {
            $CountUsers++
            $EmailSplat = [ordered] @{}

            if ($Notify.User.DaysToExpire -ge 0) {
                if ($Notify.Rule.TemplatePreExpiry) {
                    # User uses template per rule
                    $EmailSplat.Template = $Notify.Rule.TemplatePreExpiry
                } elseif ($TemplatePreExpiry) {
                    # User uses global template
                    $EmailSplat.Template = $TemplatePreExpiry
                } else {
                    # User uses built-in template
                    $EmailSplat.Template = {

                    }
                }
                if ($Notify.Rule.TemplatePreExpirySubject) {
                    $EmailSplat.Subject = $Notify.Rule.TemplatePreExpirySubject
                } elseif ($TemplatePreExpirySubject) {
                    $EmailSplat.Subject = $TemplatePreExpirySubject
                } else {
                    $EmailSplat.Subject = '[Password] Your password will expire on $DateExpiry ($TimeToExpire days)'
                }
            } else {
                if ($Notify.Rule.TemplatePostExpiry) {
                    $EmailSplat.Template = $Notify.Rule.TemplatePostExpiry
                } elseif ($TemplatePostExpiry) {
                    $EmailSplat.Template = $TemplatePostExpiry
                } else {
                    $EmailSplat.Template = {

                    }
                }
                if ($Notify.Rule.TemplatePostExpirySubject) {
                    $EmailSplat.Subject = $Notify.Rule.TemplatePostExpirySubject
                } elseif ($TemplatePostExpirySubject) {
                    $EmailSplat.Subject = $TemplatePostExpirySubject
                } else {
                    $EmailSplat.Subject = '[Password] Your password expired on $DateExpiry ($TimeToExpire days ago)'
                }
            }
            $EmailSplat.User = $Notify.User
            $EmailSplat.EmailParameters = $EmailParameters
            $EmailResult = Send-PasswordEmail @EmailSplat
            [PSCustomObject] @{
                UserPrincipalName    = $EmailSplat.User.UserPrincipalName
                SamAccountName       = $EmailSplat.User.SamAccountName
                Domain               = $EmailSplat.User.Domain
                Status               = $EmailResult.Status
                StatusError          = $EmailResult.Error
                SentTo               = $EmailResult.SentTo
                DateExpiry           = $EmailSplat.User.DateExpiry
                DaysToExpire         = $EmailSplat.User.DaysToExpire
                PasswordExpired      = $EmailSplat.User.PasswordExpired
                PasswordNeverExpires = $EmailSplat.User.PasswordNeverExpires
                PasswordLastSet      = $EmailSplat.User.PasswordLastSet
            }
            if ($UserSection.SendCountMaxium -gt 0) {
                if ($UserSection.SendCountMaximum -ge $CountUsers) {
                    break
                }
            }
        }
        Write-Color @WriteParameters -Text "[i] Sending notifications to users (sent: ", $SummaryUsersEmails.Count, ")" -Color White, Yellow, White, Yellow, White, Yellow, White
    } else {
        Write-Color @WriteParameters -Text "[i] Sending notifications to users is ", "disabled!" -Color White, Yellow, DarkMagenta
    }
    if ($ManagerSection.Enable) {
        Write-Color @WriteParameters -Text "[i] Sending notifications to managers " -Color White, Yellow, White, Yellow, White, Yellow, White
        $CountManagers = 0
        [Array] $SummaryManagersEmails = foreach ($Manager in $Summary['NotifyManager'].Keys) {
            $CountManagers++
            $ManagerUser = $CachedUsers[$Manager]
            #[Array] $ManagerAccounts = $Summary['NotifyManager'][$Manager].Values.User | Select-Object -Property DisplayName, Enabled, SamAccountName, Domain, DateExpiry, DaysToExpire, PasswordLastSet, PasswordExpired
            [Array] $ManagedUsers = $Summary['NotifyManager'][$Manager]['ManagerDefault'].Values.Output
            [Array] $ManagedUsersManagerNotCompliant = $Summary['NotifyManager'][$Manager]['ManagerNotCompliant'].Values.Output
            [Array] $ManagedUsersManagerDisabled = $Summary['NotifyManager'][$Manager]['ManagerDisabled'].Values.Output
            [Array] $ManagedUsersManagerMissing = $Summary['NotifyManager'][$Manager]['ManagerMissing'].Values.Output
            [Array] $ManagedUsersManagerMissingEmail = $Summary['NotifyManager'][$Manager]['ManagerMissingEmail'].Values.Output

            #.User | Select-Object -Property DisplayName, Enabled, SamAccountName, Domain, DateExpiry, DaysToExpire, PasswordLastSet, PasswordExpired

            $EmailSplat = [ordered] @{}

            if ($Summary['NotifyManager'][$Manager].ManagerDefault.Count -gt 0) {

                if ($TemplateManager) {
                    # User uses global template
                    $EmailSplat.Template = $TemplateManager
                } else {
                    # User uses built-in template
                    $EmailSplat.Template = {

                    }
                }
                if ($TemplateManagerSubject) {
                    $EmailSplat.Subject = $TemplateManagerSubject
                } else {
                    $EmailSplat.Subject = "[Password Expiring] Dear Manager - Your accounts are expiring!"
                }
            } elseif ($Summary['NotifyManager'][$Manager].ManagerNotCompliant.Count -gt 0) {
                if ($TemplateManagerNotCompliant) {
                    # User uses global template
                    $EmailSplat.Template = $TemplateManagerNotCompliant
                } else {
                    # User uses built-in template
                    $EmailSplat.Template = {

                    }
                }
                if ($TemplateManagerNotCompliantSubject) {
                    $EmailSplat.Subject = $TemplateManagerNotCompliantSubject
                } else {
                    $EmailSplat.Subject = "[Password Escalation] Accounts are expiring with non-compliant manager"
                }
            }

            $EmailSplat.User = $ManagerUser
            $EmailSplat.ManagedUsers = $ManagedUsers
            $EmailSplat.ManagedUsersManagerNotCompliant = $ManagedUsersManagerNotCompliant
            $EmailSplat.ManagedUsersManagerDisabled = $ManagedUsersManagerDisabled
            $EmailSplat.ManagedUsersManagerMissing = $ManagedUsersManagerMissing
            $EmailSplat.ManagedUsersManagerMissingEmail = $ManagedUsersManagerMissingEmail
            $EmailSplat.EmailParameters = $EmailParameters

            $EmailResult = Send-PasswordEmail @EmailSplat
            [PSCustomObject] @{
                UserPrincipalName    = $EmailSplat.User.UserPrincipalName
                SamAccountName       = $EmailSplat.User.SamAccountName
                Domain               = $EmailSplat.User.Domain
                Status               = $EmailResult.Status
                StatusError          = $EmailResult.Error
                SentTo               = $EmailResult.SentTo
                ManagedAccounts      = $ManagedUsers.SamAccountName
                ManagedAccountsCount = $ManagedUsers.Count
            }
            if ($Managers.SendCountMaxium -gt 0) {
                if ($UserSection.SendCountMaximum -ge $CountUsers) {
                    break
                }
            }
        }
        Write-Color @WriteParameters -Text "[i] Sending notifications to managers (sent: ", $SummaryManagersEmails.Count, ")" -Color White, Yellow, White, Yellow, White, Yellow, White
    } else {
        Write-Color @WriteParameters -Text "[i] Sending notifications to managers is ", "disabled!" -Color White, Yellow, DarkMagenta
    }

    # Create report
    New-HTML {
        New-TableOption -DataStore JavaScript -ArrayJoin -BoolAsString
        New-HTMLTab -Name 'All Users' {
            New-HTMLTable -DataTable $CachedUsers.Values -Filtering -SearchBuilder {

            }
        }
        foreach ($Rule in  $Summary['Rules'].Keys) {
            New-HTMLTab -Name $Rule {
                New-HTMLTable -DataTable $Summary['Rules'][$Rule].Values.User -SearchBuilder -Filtering {

                }
            }
        }
        New-HTMLTab -Name 'Email sent to users' {
            New-HTMLTable -DataTable $SummaryUsersEmails
        }
        New-HTMLTab -Name 'Email sent to manager' {
            New-HTMLTable -DataTable $SummaryManagersEmails
        }
    } -ShowHTML:$HTMLOptions.ShowHTML -FilePath $FilePath -Online:$HTMLOptions.Online
}