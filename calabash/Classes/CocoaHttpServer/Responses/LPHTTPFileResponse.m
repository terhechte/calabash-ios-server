#import "LPHTTPFileResponse.h"
#import "LPHTTPConnection.h"
#import "LPHTTPLogging.h"

#import <unistd.h>
#import <fcntl.h>

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

static LPLogLevel __unused lpHTTPLogLevel = LPLogLevelWarning;

#define NULL_FD  -1

@implementation LPHTTPFileResponse

- (id)initWithFilePath:(NSString *)fpath forConnection:(LPHTTPConnection *)parent {
  if ((self = [super init])) {
    LPHTTPLogTrace();

    connection = parent; // Parents retain children, children do NOT retain parents

    fileFD = NULL_FD;
    filePath = [[fpath copy] stringByResolvingSymlinksInPath];
    if (filePath == nil) {
      LPHTTPLogWarn(@"%@: Init failed - Nil filePath", LP_THIS_FILE);

      return nil;
    }

    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    if (fileAttributes == nil) {
      LPHTTPLogWarn(@"%@: Init failed - Unable to get file attributes. filePath: %@", LP_THIS_FILE, filePath);

      return nil;
    }

    fileLength = (UInt64) [[fileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
    fileOffset = 0;

    aborted = NO;

    // We don't bother opening the file here.
    // If this is a HEAD request we only need to know the fileLength.
  }
  return self;
}

- (void)abort {
  LPHTTPLogTrace();

  [connection responseDidAbort:self];
  aborted = YES;
}

- (BOOL)openFile {
  LPHTTPLogTrace();

  fileFD = open([filePath UTF8String], O_RDONLY);
  if (fileFD == NULL_FD) {
    LPHTTPLogError(@"%@[%p]: Unable to open file. filePath: %@", LP_THIS_FILE, self, filePath);

    [self abort];
    return NO;
  }

  LPHTTPLogVerbose(@"%@[%p]: Open fd[%i] -> %@", LP_THIS_FILE, self, fileFD, filePath);

  return YES;
}

- (BOOL)openFileIfNeeded {
  if (aborted) {
    // The file operation has been aborted.
    // This could be because we failed to open the file,
    // or the reading process failed.
    return NO;
  }

  if (fileFD != NULL_FD) {
    // File has already been opened.
    return YES;
  }

  return [self openFile];
}

- (UInt64)contentLength {
  LPHTTPLogTrace();

  return fileLength;
}

- (UInt64)offset {
  LPHTTPLogTrace();

  return fileOffset;
}

- (void)setOffset:(UInt64)offset {
  LPHTTPLogVerbose(@"%@[%p]: setOffset:%llu", LP_THIS_FILE, self, offset);

  if (![self openFileIfNeeded]) {
    // File opening failed,
    // or response has been aborted due to another error.
    return;
  }

  fileOffset = offset;

  off_t result = lseek(fileFD, (off_t) offset, SEEK_SET);
  if (result == -1) {
    LPHTTPLogError(@"%@[%p]: lseek failed - errno(%i) filePath(%@)", LP_THIS_FILE, self, errno, filePath);

    [self abort];
  }
}

- (NSData *)readDataOfLength:(NSUInteger)length {
  LPHTTPLogVerbose(@"%@[%p]: readDataOfLength:%lu", LP_THIS_FILE, self, (unsigned long) length);

  if (![self openFileIfNeeded]) {
    // File opening failed,
    // or response has been aborted due to another error.
    return nil;
  }

  // Determine how much data we should read.
  //
  // It is OK if we ask to read more bytes than exist in the file.
  // It is NOT OK to over-allocate the buffer.

  UInt64 bytesLeftInFile = fileLength - fileOffset;

  NSUInteger bytesToRead = (NSUInteger) MIN(length, bytesLeftInFile);

  // Make sure buffer is big enough for read request.
  // Do not over-allocate.

  if (buffer == NULL || bufferSize < bytesToRead) {
    bufferSize = bytesToRead;
    buffer = reallocf(buffer, (size_t) bufferSize);

    if (buffer == NULL) {
      LPHTTPLogError(@"%@[%p]: Unable to allocate buffer", LP_THIS_FILE, self);

      [self abort];
      return nil;
    }
  }

  // Perform the read

  LPHTTPLogVerbose(@"%@[%p]: Attempting to read %lu bytes from file", LP_THIS_FILE, self, (unsigned long) bytesToRead);

  ssize_t result = read(fileFD, buffer, bytesToRead);

  // Check the results

  if (result < 0) {
    LPHTTPLogError(@"%@: Error(%i) reading file(%@)", LP_THIS_FILE, errno, filePath);

    [self abort];
    return nil;
  }
  else if (result == 0) {
    LPHTTPLogError(@"%@: Read EOF on file(%@)", LP_THIS_FILE, filePath);

    [self abort];
    return nil;
  }
  else // (result > 0)
  {
    LPHTTPLogVerbose(@"%@[%p]: Read %ld bytes from file", LP_THIS_FILE, self, (long) result);

    fileOffset += result;

    return [NSData dataWithBytes:buffer length:result];
  }
}

- (BOOL)isDone {
  BOOL result = (fileOffset == fileLength);

  LPHTTPLogVerbose(@"%@[%p]: isDone - %@", LP_THIS_FILE, self, (result ? @"YES" : @"NO"));

  return result;
}

- (NSString *)filePath {
  return filePath;
}

- (void)dealloc {
  LPHTTPLogTrace();

  if (fileFD != NULL_FD) {
    LPHTTPLogVerbose(@"%@[%p]: Close fd[%i]", LP_THIS_FILE, self, fileFD);

    close(fileFD);
  }

  if (buffer)
    free(buffer);

}

@end
