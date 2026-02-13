# Calls for troubleshooting in the logmein command prompt 

## Accessing share drive

```powershell
net use Z: "\\{IP address of NTFS share}\{property name in share}" /user:universal-username "universal-password" /persistent:yes
```
## Copy command

```powershell
Copy-Item -Path "C:\Staging_Logmein_central" -Destination "Z:\01-PCARCHIVE" -Recurse -Force -ErrorAction Stop
```

## Property drive information
FS2 FTP in logmein has all of the property credentials stored for reference
