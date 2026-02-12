# Gates Hudson LogMeIn Remote Backup
## Workflow
1. Load PcDetails.json into C:\ of remote PC.
2. Upload ```logmein-remote-backup.ps1``` script in remote manager of LogMeIn Central for a batch of PCs to create staging folder for before copying to (Prop) network share drive.
3. From the LogMeIn file manager of the remote PC, copy over the Staging_Logmein_central folder to (Prop).
4. After the upload is completed, run the copy-count-checker.ps1 script in a specific PC copied over to (Prop) with tolerance of ~100 or less as a quick test in determining whether or not a machine was turned off during the copy stage.

## Usage of copy-count-checker.ps1
Run inside the PC directory that needs to be checked.

```powershell
.\copy-count-checker.ps1 -ToleranceCount 100
```
