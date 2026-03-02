# Gates Hudson Internship (2026) 
### LogMeIn Central - Remote Backup Project
### Workflow
1. Load PcDetails.json into C:\ of remote PC.
2. Upload ```stage.ps1``` script in remote manager of LogMeIn Central for a batch of PCs to create staging folder for before copying to (Prop) network share drive.
> Some systems on older versions of Powershell and systems without a File Manager in LogMeIn Central will need the ```no-map.ps1``` script.
3. From the LogMeIn Central File Manager of the remote PC, copy the Staging_logmein_central folder to 01-PCARCHIVE for each Prop folder.
---
### Additional Scripts
- ```report.ps1``` - This script will create a report of the remote PC's volume and file count based on filter settings created in ```stage.ps1``` 
- ```delete.ps1``` - Use this script in a LogMein Central job to purge and free up disk space for the staging folders created after running ```stage.ps1```
- ```mappings.sh``` - Used locally after recreating the Prop drive folder structure of all prop folders and their PCs. Generates mappings to load into C:\ of each PC before running a ```stage.ps1``` job
