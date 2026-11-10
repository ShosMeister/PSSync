# PSSync
PSSync is a PowerShell directory synchronization utility inspired by the behavior of 'rsync'.

It synchronizes files and directories from a source tree to a destination tree using file timestamps to determine whether an existing destination file needs to be updated.


## Features
- Copies files that are missing from the destination.
- Includes hidden and system files and directories in enumeration.
- Supports rsync-style path glob exclusions from a text file with `-ExcludeFrom`.
- Preserves excluded destination paths during `-Mirror` runs, or deletes them with `-DeleteExcluded` (like rsync's `--delete-excluded`).
- Defers files temporarily locked or removed during scanning and retries them on a later run.
- Updates destination files when the source file is newer.
- Leaves destination files alone when they are the same age or newer.
- Creates destination directories required by the source.
- Identifies destination-only files and directories.
- Optional '-Mirror' mode removes destination-only files and directories.
- Supports PowerShell's '-WhatIf' behavior for previewing planned changes.
- Supports '-ChangesOnly' to suppress noisy no-change messages.
- Displays progress while enumerating and analyzing large directory trees.
- Detects file/directory conflicts before modifying the destination.
- Verifies copied and updated files using SHA-256 after transfer.
- Preserves source file creation and last-write timestamps after a successful verified transfer.
- Uses a SHA-256 self-test before synchronization modifies the destination.
- Reports file-system operation errors and provides a final summary.


## Nightly backup
The `Backup` folder contains a ready-made nightly backup that mirrors local drives to a NAS share with PSSync: live logging to a synced folder, failure email, Outlook handling, and a Task Scheduler registration script. See `Backup/README.md` for setup.


## Requirements
- Windows PowerShell 5.1 or later
- Pester 3.4.0 or compatible Pester version for running the included tests


## Installation
PSSync is currently distributed as a PowerShell module file.

Copy 'PSSync.psm1' to a location on your PowerShell module path, or import it directly from the project directory.

For example:

'''powershell
Import-Module .\PSSync.psm1 -Force
'''

The module exports the 'PSSync' function.


## Basic Usage
'''powershell
PSSync "C:\Source" "D:\Destination"
'''

The source must be an existing directory. The destination directory is created when it does not already exist.

Use `-ExcludeFrom` to load patterns from a text file. Blank lines and lines beginning with `#` are ignored. A leading `/` anchors a pattern to the source root; a trailing `/` marks a directory; `*` and `?` match within one path component, while `**` can span path components. Matching paths are excluded from both trees, so excluded destination items are kept during mirror cleanup.

```powershell
PSSync "C:\Source" "D:\Destination" -Mirror -ExcludeFrom .\exclusions.txt -WhatIf
```


## Mirror Mode
Use '-Mirror' when the destination should also be cleaned of items that do not exist in the source:

'''powershell
PSSync "C:\Source" "D:\Destination" -Mirror
'''

Without '-Mirror', destination-only files and directories are retained.

**Use '-Mirror' carefully.** It can permanently delete destination files and directories.

### Deleting excluded items
By default, destination items that match an exclusion pattern are left alone during `-Mirror`. Add `-DeleteExcluded` (only allowed together with `-Mirror`) to delete them as well; an excluded directory is deleted with everything in it:

```powershell
PSSync "C:\Source" "D:\Destination" -Mirror -ExcludeFrom .\exclusions.txt -DeleteExcluded -WhatIf
```

With `-WhatIf` each one is reported as `WOULD DELETE EXCLUDED:` (or `WOULD DELETE EXCLUDED DIRECTORY:`). Preview after any change to the exclusion file: a wrong pattern deletes that data from the destination.


## WhatIf
Use '-WhatIf' to preview the synchronization without modifying the file system:

'''powershell
PSSync "C:\Source" "D:\Destination" -WhatIf
'''

With '-Mirror':

'''powershell
PSSync "C:\Source" "D:\Destination" -Mirror -WhatIf
'''

The WhatIf output reports the operations that would be performed and provides a summary.


## ChangesOnly
Large directory trees can produce a lot of output for files that do not need to change.

Use '-ChangesOnly' to suppress those no-change messages:

'''powershell
PSSync "C:\Source" "D:\Destination" -ChangesOnly
'''

With '-ChangesOnly':

- 'UNCHANGED' messages are suppressed during normal operation.
- 'WOULD LEAVE ALONE' messages are suppressed during '-WhatIf'.
- Copies, updates, deletions, errors, and other actionable messages remain visible.
- The final summary still includes the unchanged/no-action counts.

'-ChangesOnly' changes output only; it does not change synchronization behavior.


## Synchronization Rules
For each source item:

1. A missing destination directory is created.
2. A missing source file is copied.
3. An existing destination file is updated when the source 'LastWriteTimeUtc' is newer.
4. A destination file that is the same age or newer is left unchanged.
5. Destination-only files are retained unless '-Mirror' is specified.
6. Destination-only directories are retained unless '-Mirror' is specified.
7. Mirror directory cleanup is performed from the deepest directory toward the destination root.
8. File/directory conflicts at the same relative path are detected before synchronization begins.
9. Files selected for copy or update are verified using SHA-256 after transfer.
10. The SHA-256 verification mechanism is self-tested before synchronization modifies the destination.
11. After a successful verified copy or update, the destination file's `CreationTimeUtc` and `LastWriteTimeUtc` are set to the corresponding source timestamps.
12. Files that do not need to be transferred are left untouched, including their destination timestamps.
13. Hidden and system files and directories are included during enumeration.


## Progress Reporting
PSSync displays progress during operations that can take significant time on large directory trees.

The progress stages include:

- Enumerating source files
- Enumerating source directories
- Enumerating destination files
- Enumerating destination directories
- Determining workload
- Checking for file/directory conflicts
- Analyzing source and destination

The analysis stage provides a percentage based on the items analyzed relative to the synchronization workload.


## File Verification
PSSync verifies every file that it copies or updates.

The verification process is:

1. The source file is copied or updated, and its SHA-256 hash is calculated from
   the same bytes as they are copied, so each source file is read only once.
2. The source file's size and last-write time are checked against their values when
   the copy started. If either changed, the file is deferred to the next run.
3. The destination file is hashed.
4. The transfer is successful only when the source and destination SHA-256 values match.

This protects against a source file changing during the transfer and verifies that
the destination contents match the source contents that were copied. Files that are
unchanged are never read.

A file that is locked by another program, or disappears, while it is being copied is
reported as a deferred transient file rather than an error, and is retried on the next run.

A source or destination path of 260 characters or more cannot be opened by Windows PowerShell 5.1. Such files are
reported as errors (`Path too long`), not deferred, so they are never skipped silently. PowerShell 7 supports long paths.

When run with `-Verbose`, PSSync also writes `COPYING:`/`UPDATING:` before each transfer,
a `PROGRESS:` line about every 10 seconds during long transfers, and `VERIFYING:` before
the destination hash.

PSSync uses SHA-256, a FIPS-approved hashing algorithm, for verification of files
transferred during synchronization. PSSync does not use MD5 or SHA-1 for file
verification.

PSSync performs a SHA-256 self-test before synchronization modifies the destination.
If the verification mechanism is unavailable or fails the self-test, PSSync stops
before making synchronization changes.

PSSync does not claim FIPS 140 certification or compliance.

## Output
Normal execution reports operations such as:

'''text
COPIED: folder\newfile.txt
UPDATED: folder\changedfile.txt
UNCHANGED: folder\existingfile.txt
DELETED: oldfile.txt
DELETED DIRECTORY: oldfolder
EXTRANEOUS: retained-destination-file.txt
'''

The final summary reports counts for:

- Copied files
- Updated files
- Unchanged files
- Deleted files
- Deleted directories
- Errors


## Error Handling
Source validation and other pre-synchronization validation failures produce terminating errors.

Individual file-system operation failures are reported as errors and included in the final error count. PSSync continues processing other planned operations where possible.


## Limitations
PSSync currently:

- Uses 'LastWriteTimeUtc' to determine whether an existing destination file needs
  to be transferred. SHA-256 is used to verify files that are transferred.
- Does not use hashes to determine whether unchanged files need to be transferred.
- Does not provide include filters; exclusions are supported through `-ExcludeFrom`.
- Does not provide external logging.
- Is intended primarily as a straightforward directory synchronization utility rather than a full replacement for mature synchronization tools.


## Testing
The project includes a Pester test suite covering the core synchronization behavior, including:

- Missing file copies
- Newer-file updates
- Unchanged and newer destination files
- Mirror file and directory deletion
- WhatIf behavior
- ChangesOnly output
- Nested directories
- Empty source/destination scenarios
- File/directory conflicts
- Destination path errors
- Summary and error handling
- SHA-256 transfer verification
- SHA-256 pre-synchronization self-test
- Source creation and last-write timestamp preservation for copied and updated files
- Unchanged destination timestamp preservation

Run the tests from the project directory with:

'''powershell
Remove-Module PSSync -ErrorAction SilentlyContinue
Import-Module .\PSSync.psm1 -Force
Invoke-Pester .\Tests\PSSync.Tests.ps1
'''


## Reporting Bugs and Requesting Features
Please use the GitHub repository's **Issues** section to report bugs or request features.

When reporting a problem, include:

- PSSync version
- PowerShell version
- Windows version
- The command that was run
- Whether '-Mirror', '-WhatIf', or '-ChangesOnly' was used
- The relevant output or error message
- A description of the expected and actual behavior

Using GitHub Issues keeps reports organized and avoids requiring a personal email address in the project documentation.


## License
PSSync is licensed under the MIT License.

See the [LICENSE](LICENSE) file for the complete license text.
