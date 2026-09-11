# GenAI-generated code — reviewed and approved by: <name> <date>
#requires -Version 7.0

BeforeAll {
    Import-Module "$PSScriptRoot\..\Modules\DateHelper.psm1" -Force
    $script:Tz = 'Central European Standard Time'  # CET/CEST: UTC+1 winter, UTC+2 summer
}

Describe 'DateHelper edge cases' {

    Context 'DST-aware UTC conversions (Convert-ToUtc / Convert-ToLocal)' {

        It 'applies a +1h offset in winter (January, standard time)' {
            $localWinter = [datetime]::new(2026, 1, 15, 12, 0, 0, [System.DateTimeKind]::Unspecified)
            $utc = Convert-ToUtc -LocalDateTime $localWinter -TimeZoneId $script:Tz
            # 12:00 CET -> 11:00 UTC
            ($localWinter - $utc).TotalHours | Should -Be 1
            $utc.Hour | Should -Be 11
        }

        It 'applies a +2h offset in summer (July, daylight time)' {
            $localSummer = [datetime]::new(2026, 7, 15, 12, 0, 0, [System.DateTimeKind]::Unspecified)
            $utc = Convert-ToUtc -LocalDateTime $localSummer -TimeZoneId $script:Tz
            # 12:00 CEST -> 10:00 UTC
            ($localSummer - $utc).TotalHours | Should -Be 2
            $utc.Hour | Should -Be 10
        }

        It 'round-trips a winter UTC instant through Convert-ToLocal | Convert-ToUtc' {
            $utcWinter = [datetime]::new(2026, 1, 15, 9, 0, 0, [System.DateTimeKind]::Utc)
            $local = Convert-ToLocal -UtcDateTime $utcWinter -TimeZoneId $script:Tz
            $backToUtc = Convert-ToUtc -LocalDateTime $local -TimeZoneId $script:Tz
            $backToUtc | Should -Be $utcWinter
        }

        It 'round-trips a summer UTC instant through Convert-ToLocal | Convert-ToUtc' {
            $utcSummer = [datetime]::new(2026, 7, 15, 9, 0, 0, [System.DateTimeKind]::Utc)
            $local = Convert-ToLocal -UtcDateTime $utcSummer -TimeZoneId $script:Tz
            $backToUtc = Convert-ToUtc -LocalDateTime $local -TimeZoneId $script:Tz
            $backToUtc | Should -Be $utcSummer
        }
    }

    Context 'Get-BusinessDate night-audit cutover' {

        It 'nightAuditHour = 0 (midnight) returns local-yesterday' {
            # ReferenceDate is a fixed UTC instant; local (CEST, +2h) is 2026-07-15 12:00.
            # With a midnight cutover the current business date = today (07-15),
            # so the last fully-closed business date = local yesterday (07-14).
            $ref = [datetime]::new(2026, 7, 15, 10, 0, 0, [System.DateTimeKind]::Utc)
            $hotel = @{ hotelCode = 'MIDNIGHT'; timeZoneId = $script:Tz; nightAuditHour = 0 }
            $bd = Get-BusinessDate -Hotel $hotel -ReferenceDate $ref
            $bd.Date | Should -Be ([datetime]::new(2026, 7, 14, 0, 0, 0, [System.DateTimeKind]::Unspecified))
        }

        It 'falls back to midnight when nightAuditHour is absent (no throw, resolves a date)' {
            $ref = [datetime]::new(2026, 7, 15, 10, 0, 0, [System.DateTimeKind]::Utc)
            $hotel = @{ hotelCode = 'NOAUDITHOUR'; timeZoneId = $script:Tz }  # no nightAuditHour key
            { Get-BusinessDate -Hotel $hotel -ReferenceDate $ref } | Should -Not -Throw
            # Same result as an explicit midnight cutover: local yesterday.
            $bd = Get-BusinessDate -Hotel $hotel -ReferenceDate $ref
            $bd.Date | Should -Be ([datetime]::new(2026, 7, 14, 0, 0, 0, [System.DateTimeKind]::Unspecified))
        }

        It 'throws when timeZoneId is missing (required field)' {
            $hotel = @{ hotelCode = 'NOTZ'; nightAuditHour = 3 }  # no timeZoneId key
            { Get-BusinessDate -Hotel $hotel -ReferenceDate ([datetime]::UtcNow) } | Should -Throw
        }
    }
}
