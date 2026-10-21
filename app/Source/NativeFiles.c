#include "HostInternal.h"
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <pthread.h>

#define PG_FDS 512
static struct { int native; DIR *dir; uint64_t position; char path[PATH_MAX]; } descriptors[PG_FDS];
static pthread_mutex_t filesLock = PTHREAD_MUTEX_INITIALIZER;
static char filesRoot[PATH_MAX];

static int guestError(int e) {
  switch(e) {
    case 0:return 0; case EACCES:return 2; case EAGAIN:return 6; case EBADF:return 8;
    case EBUSY:return 10; case EEXIST:return 20; case EFAULT:return 21;
    case EFBIG:return 22; case EINTR:return 27; case EINVAL:return 28; case EIO:return 29;
    case EISDIR:return 31; case ELOOP:return 32; case EMFILE:return 33; case ENAMETOOLONG:return 37;
    case ENFILE:return 41; case ENOENT:return 44; case ENOMEM:return 48; case ENOSPC:return 51;
    case ENOSYS:return 52; case ENOTDIR:return 54; case ENOTEMPTY:return 55; case ENOTSUP:return 58;
    case EPERM:return 63; case EPIPE:return 64; case ERANGE:return 68; case EROFS:return 69;
    case ESPIPE:return 70; case EXDEV:return 75; default:return 29;
  }
}
static u32 failure(void) { return (u32)-guestError(errno); }
void pg_files_init(const char *root) {
  snprintf(filesRoot,sizeof filesRoot,"%s",root);
  mkdir(root,0700);
  for(int i=0;i<PG_FDS;i++) descriptors[i].native=-1;
  const char *paths[]={"/tmp","/home","/home/web_user","/dev","/proc","/proc/self","/proc/self/fd"};
  for(size_t i=0;i<sizeof paths/sizeof *paths;i++) {
    char path[PATH_MAX]; snprintf(path,sizeof path,"%s%s",root,paths[i]); mkdir(path,0700);
  }
}
static int nativeFD(u32 fd) { if(fd>=PG_FDS||descriptors[fd].native<0){errno=EBADF;return -1;}return descriptors[fd].native; }
static int pathAt(struct w2c_env *host,u32 fd,u64 address,char *physical,char *virtualPath) {
  const char *input=pg_string(host,address);
  char merged[PATH_MAX];
  if(input[0]=='/') {
    if(strlen(input)>=sizeof merged){errno=ENAMETOOLONG;return -1;}
    strcpy(merged,input);
  } else {
    const char *base="/";
    if(fd!=(u32)-100) {
      if(nativeFD(fd)<0)return -1;
      struct stat s;if(fstat(descriptors[fd].native,&s)<0)return -1;
      if(!S_ISDIR(s.st_mode)){errno=ENOTDIR;return -1;}
      base=descriptors[fd].path;
    }
    if(snprintf(merged,sizeof merged,"%s/%s",base,input)>=(int)sizeof merged){errno=ENAMETOOLONG;return -1;}
  }
  char normalized[PATH_MAX]=""; char *save=NULL;
  for(char *part=strtok_r(merged,"/",&save);part;part=strtok_r(NULL,"/",&save)) {
    if(!strcmp(part,"."))continue;
    if(!strcmp(part,"..")) {char *slash=strrchr(normalized,'/');if(slash)*slash=0;continue;}
    size_t n=strlen(normalized);normalized[n]='/';strcpy(normalized+n+1,part);
  }
  if(!normalized[0])strcpy(normalized,"/");
  if(virtualPath)strcpy(virtualPath,normalized);
  if(snprintf(physical,PATH_MAX,"%s%s",filesRoot,normalized)>=PATH_MAX){errno=ENAMETOOLONG;return -1;}
  return 0;
}
static int openFlags(u32 flags) {
  int out=(flags&3)==2?O_RDWR:(flags&3)==1?O_WRONLY:O_RDONLY;
  if(flags&64)out|=O_CREAT;if(flags&128)out|=O_EXCL;if(flags&512)out|=O_TRUNC;
  if(flags&1024)out|=O_APPEND;if(flags&2048)out|=O_NONBLOCK;
  if(flags&65536)out|=O_DIRECTORY;if(flags&131072)out|=O_NOFOLLOW;
  return out|O_CLOEXEC;
}
u32 w2c_env_0x5F_syscall_openat(struct w2c_env *host,u32 fd,u64 name,u32 flags,u64 args) {
  char path[PATH_MAX],virtualPath[PATH_MAX];
  pthread_mutex_lock(&filesLock);
  if(pathAt(host,fd,name,path,virtualPath)<0){u32 e=failure();pthread_mutex_unlock(&filesLock);return e;}
  int mode=args?*(u32 *)pg_pointer(host,args,4):0666;
  int n=!strcmp(virtualPath,"/dev/null")?open("/dev/null",openFlags(flags),mode):open(path,openFlags(flags),mode);
  if(n<0){u32 e=failure();pthread_mutex_unlock(&filesLock);return e;}
  for(int i=3;i<PG_FDS;i++)if(descriptors[i].native<0){descriptors[i].native=n;strcpy(descriptors[i].path,virtualPath);pthread_mutex_unlock(&filesLock);return i;}
  close(n);pthread_mutex_unlock(&filesLock);return (u32)-33;
}
static void writeStat(struct w2c_env *host,u64 at,const struct stat *s) {
  uint8_t *p=pg_pointer(host,at,104);memset(p,0,104);
#define STORE(type,offset,value) do {type v=(type)(value);memcpy(p+offset,&v,sizeof v);}while(0)
  STORE(u32,0,s->st_dev);STORE(u32,4,s->st_mode);STORE(u64,8,s->st_nlink);
  STORE(u32,16,s->st_uid);STORE(u32,20,s->st_gid);STORE(u32,24,s->st_rdev);
  STORE(int64_t,32,s->st_size);STORE(u32,40,s->st_blksize);STORE(u32,44,s->st_blocks);
  STORE(int64_t,48,s->st_atimespec.tv_sec);STORE(u64,56,s->st_atimespec.tv_nsec);
  STORE(int64_t,64,s->st_mtimespec.tv_sec);STORE(u64,72,s->st_mtimespec.tv_nsec);
  STORE(int64_t,80,s->st_ctimespec.tv_sec);STORE(u64,88,s->st_ctimespec.tv_nsec);STORE(u64,96,s->st_ino);
#undef STORE
}
u32 w2c_env_0x5F_syscall_fstat64(struct w2c_env *h,u32 fd,u64 out){struct stat s;int n=nativeFD(fd);if(n<0||fstat(n,&s)<0)return failure();writeStat(h,out,&s);return 0;}
u32 w2c_env_0x5F_syscall_newfstatat(struct w2c_env *h,u32 fd,u64 name,u64 out,u32 flags){char path[PATH_MAX];struct stat s;if(pathAt(h,fd,name,path,NULL)<0)return failure();if((flags&256?lstat(path,&s):stat(path,&s))<0)return failure();writeStat(h,out,&s);return 0;}
u32 w2c_env_0x5F_syscall_stat64(struct w2c_env *h,u64 name,u64 out){return w2c_env_0x5F_syscall_newfstatat(h,-100,name,out,0);}
u32 w2c_env_0x5F_syscall_lstat64(struct w2c_env *h,u64 name,u64 out){return w2c_env_0x5F_syscall_newfstatat(h,-100,name,out,256);}
u32 w2c_env_0x5F_syscall_getcwd(struct w2c_env *h,u64 out,u64 size){if(size<2)return (u32)-68;memcpy(pg_pointer(h,out,2),"/",2);return 2;}
u32 w2c_env_0x5F_syscall_mkdirat(struct w2c_env *h,u32 fd,u64 name,u32 mode){char p[PATH_MAX];if(pathAt(h,fd,name,p,NULL)<0||mkdir(p,mode)<0)return failure();return 0;}
u32 w2c_env_0x5F_syscall_unlinkat(struct w2c_env *h,u32 fd,u64 name,u32 flags){char p[PATH_MAX];if(pathAt(h,fd,name,p,NULL)<0||(flags&512?rmdir(p):unlink(p))<0)return failure();return 0;}
u32 w2c_env_0x5F_syscall_rmdir(struct w2c_env *h,u64 name){return w2c_env_0x5F_syscall_unlinkat(h,-100,name,512);}
u32 w2c_env_0x5F_syscall_renameat(struct w2c_env *h,u32 a,u64 old,u32 b,u64 new){char p[PATH_MAX],q[PATH_MAX];if(pathAt(h,a,old,p,NULL)<0||pathAt(h,b,new,q,NULL)<0||rename(p,q)<0)return failure();return 0;}
u32 w2c_env_0x5F_syscall_ftruncate64(struct w2c_env *h,u32 fd,u64 length){int n=nativeFD(fd);if(n<0||ftruncate(n,(int64_t)length)<0)return failure();return 0;}
u32 w2c_wasi__snapshot__preview1_fd_close(struct w2c_wasi__snapshot__preview1 *h,u32 fd){
  if(fd<3)return 0;pthread_mutex_lock(&filesLock);int n=nativeFD(fd);if(n<0){pthread_mutex_unlock(&filesLock);return 8;}
  if(descriptors[fd].dir)closedir(descriptors[fd].dir);else close(n);
  memset(&descriptors[fd],0,sizeof descriptors[fd]);descriptors[fd].native=-1;pthread_mutex_unlock(&filesLock);return 0;
}
u32 pg_file_io(struct w2c_env *h,u32 fd,u64 vectors,u64 count,u64 offset,u64 out,bool writing,bool positioned){
  if(count>SIZE_MAX/16)return 28;
  u64 *iov=pg_pointer(h,vectors,count*16);u64 total=0;int n=fd<3?-1:nativeFD(fd);
  if(fd>=3&&n<0)return 8;if(writing&&fd==0)return 8;if(!writing&&(fd==1||fd==2))return 8;
  for(u64 i=0;i<count;i++){
    u64 size=iov[2*i+1];if(size>SSIZE_MAX)return 28;void *p=pg_pointer(h,iov[2*i],size);ssize_t actual;
    if(fd>=3)PGMeshTouch(p,size);		// the kernel can't fault a released mesh page back in (GTA-152)
    if(fd==0)actual=0;
    else if(fd<3){char line[2048];u64 left=size;char *s=p;while(left){size_t len=left<2047?left:2047;memcpy(line,s,len);line[len]=0;pg_log(line);s+=len;left-=len;}actual=size;}
    else if(writing)actual=positioned?pwrite(n,p,size,(int64_t)(offset+total)):write(n,p,size);
    else actual=positioned?pread(n,p,size,(int64_t)(offset+total)):read(n,p,size);
    if(actual<0){if(!total)return guestError(errno);break;}total+=actual;if((u64)actual<size)break;
  }
  *(u64 *)pg_pointer(h,out,8)=total;return 0;
}
u32 w2c_wasi__snapshot__preview1_fd_read(struct w2c_wasi__snapshot__preview1 *h,u32 fd,u64 v,u64 c,u64 o){return pg_file_io(h->env,fd,v,c,0,o,false,false);}
u32 w2c_wasi__snapshot__preview1_fd_pread(struct w2c_wasi__snapshot__preview1 *h,u32 fd,u64 v,u64 c,u64 at,u64 o){return pg_file_io(h->env,fd,v,c,at,o,false,true);}
u32 w2c_wasi__snapshot__preview1_fd_pwrite(struct w2c_wasi__snapshot__preview1 *h,u32 fd,u64 v,u64 c,u64 at,u64 o){return pg_file_io(h->env,fd,v,c,at,o,true,true);}
u32 w2c_wasi__snapshot__preview1_fd_seek(struct w2c_wasi__snapshot__preview1 *h,u32 fd,u64 offset,u32 whence,u64 out){if(whence>2)return 28;int n=nativeFD(fd);if(n<0)return 8;off_t pos=lseek(n,(int64_t)offset,whence);if(pos<0)return guestError(errno);*(u64 *)pg_pointer(h->env,out,8)=pos;return 0;}
u32 w2c_env_0x5F_syscall_getdents64(struct w2c_env *h,u32 fd,u64 at,u64 capacity){
  pthread_mutex_lock(&filesLock);int n=nativeFD(fd);if(n<0){pthread_mutex_unlock(&filesLock);return (u32)-8;}
  if(!descriptors[fd].dir){int copy=dup(n);descriptors[fd].dir=fdopendir(copy);if(!descriptors[fd].dir){if(copy>=0)close(copy);u32 e=failure();pthread_mutex_unlock(&filesLock);return e;}}
  uint8_t *output=pg_pointer(h,at,capacity);u64 size=0;struct dirent *entry;
  while(capacity-size>=280&&(entry=readdir(descriptors[fd].dir))){uint8_t *p=output+size;memset(p,0,280);*(u64 *)p=entry->d_ino;*(u64 *)(p+8)=++descriptors[fd].position*280;*(uint16_t *)(p+16)=280;p[18]=entry->d_type;snprintf((char *)p+19,256,"%s",entry->d_name);size+=280;}
  pthread_mutex_unlock(&filesLock);return size;
}
u32 w2c_env_0x5F_syscall_fcntl64(struct w2c_env *h,u32 fd,u32 command,u64 args){
  int n=nativeFD(fd);if(n<0)return failure();
  if(command==1||command==2)return 0;
  if(command==3){int f=fcntl(n,F_GETFL);if(f<0)return failure();return (f&O_ACCMODE)|(f&O_APPEND?1024:0)|(f&O_NONBLOCK?2048:0);}
  if(command==4){u32 f=*(u32 *)pg_pointer(h,args,4);return fcntl(n,F_SETFL,(f&1024?O_APPEND:0)|(f&2048?O_NONBLOCK:0))<0?failure():0;}
  if(command==5||command==6||command==7)return (u32)-28;
  return (u32)-28;
}
u32 w2c_env_0x5F_syscall_ioctl(struct w2c_env *h,u32 fd,u32 request,u64 args){return (u32)-59;}
u32 w2c_env_0x5F_syscall_statfs64(struct w2c_env *h,u64 path,u64 size,u64 out) {
  char physical[PATH_MAX];if(pathAt(h,-100,path,physical,NULL)<0)return failure();
  // Free space of a folder that doesn't exist yet (the Replay editor asks before creating its
  // folder) is the free space of its nearest existing parent.
  struct statvfs s;
  while(statvfs(physical,&s)<0){
    if(errno!=ENOENT&&errno!=ENOTDIR)return failure();
    char *slash=strrchr(physical,'/');if(!slash||slash==physical)return failure();
    *slash=0;
  }
  if(size<84)return (u32)-28;
  uint8_t *p=pg_pointer(h,out,size);memset(p,0,size);
  *(u32 *)(p+8)=s.f_bsize;*(u32 *)(p+72)=s.f_frsize;
  *(u64 *)(p+16)=s.f_blocks;*(u64 *)(p+24)=s.f_bfree;*(u64 *)(p+32)=s.f_bavail;
  *(u64 *)(p+40)=s.f_files;*(u64 *)(p+48)=s.f_ffree;
  *(u32 *)(p+56)=s.f_fsid;*(u32 *)(p+64)=s.f_namemax;*(u32 *)(p+80)=s.f_flag;return 0;
}
