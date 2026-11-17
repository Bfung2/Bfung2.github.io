# Staff acceptance review and manual record backups

## Browser acceptance completed

The existing employee session successfully opened My work, Overview, Order workflow, Sales contributions and Schedule. The account had no current jobs or contributions. It retained its existing order, service-request, customer-detail, claim, status and schedule permissions. No permissions were widened or reduced.

Direct navigation to Employees returned to My work; Team activity was denied; Internal notes reported notes viewing disabled. Owner administration controls were absent from the employee dashboard. No console errors were observed during these checks. Earlier owner MFA verification and the owner dashboard were verified in the same implementation session.

No real order, payout, employee setting, schedule or payment was changed for acceptance testing. There are no current orders to exercise a populated workflow in this production session; isolated database tests cover assignment isolation, private-note edit/view restrictions, inactive accounts and customer/anonymous denial. Mobile drawer/CSS behavior is tested automatically; the connected browser's viewport override previously failed to apply, so a visual phone walkthrough remains outstanding.

## Improvements

Employee contribution pages describe employee history rather than instructing them to mark owner payouts. Private backup is an owner-only workspace route with a fresh MFA-checked server export. The exported business records are encrypted in the owner's browser using a password the owner chooses. A separate local file check verifies decryption, authentication and row counts without modifying the database.

No automatic backup, full private database dump, production restore or paid plan upgrade was performed. Follow `docs/private-backup-recovery.md` for coverage, exclusions and the remaining full recovery procedure. A real encrypted download still requires the owner to choose and retain a private encryption password.
