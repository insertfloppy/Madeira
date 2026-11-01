
/* madeira-bcd: appended to file.c by build.sh. NtCreateFile (and NtOpenFile,
 * which calls it) and NtQueryInformationFile report to ios_file_watch_note
 * (virtual_ios.c), which logs [file-watch] lines for the file named by
 * MADEIRA_FILE_WATCH (unset: icudtl.dat in gmod.exe only). */
void ios_file_watch_note( const char *what, unsigned int status, HANDLE handle,
                          const OBJECT_ATTRIBUTES *attr, ULONGLONG a, ULONGLONG b );

NTSTATUS WINAPI NtCreateFile( HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr,
                              IO_STATUS_BLOCK *io, LARGE_INTEGER *alloc_size,
                              ULONG attributes, ULONG sharing, ULONG disposition,
                              ULONG options, void *ea_buffer, ULONG ea_length )
{
    NTSTATUS status = ios_unwatched_NtCreateFile( handle, access, attr, io, alloc_size, attributes,
                                                  sharing, disposition, options, ea_buffer, ea_length );
    ios_file_watch_note( "NtCreateFile", status, status ? 0 : *handle, attr, access,
                         ((ULONGLONG)sharing << 32) | options );
    return status;
}

NTSTATUS WINAPI NtQueryInformationFile( HANDLE handle, IO_STATUS_BLOCK *io,
                                        void *ptr, ULONG len, FILE_INFORMATION_CLASS class )
{
    NTSTATUS status = ios_unwatched_NtQueryInformationFile( handle, io, ptr, len, class );

    if (class == FileStandardInformation)
        ios_file_watch_note( "NtQueryInformationFile(Standard)", status, handle, NULL, class,
                             status ? 0 : ((FILE_STANDARD_INFORMATION *)ptr)->EndOfFile.QuadPart );
    return status;
}
