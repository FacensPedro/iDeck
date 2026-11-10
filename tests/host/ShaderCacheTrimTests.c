#include <assert.h>
#include <stdio.h>
#include <sys/stat.h>
#include "cache_trim.h"
static void sql(sqlite3 *db, const char *command) {
  char *error = NULL;
  int rc = sqlite3_exec(db, command, NULL, NULL, &error);
  if (rc != SQLITE_OK) fprintf(stderr,"%s: %s\n",command,error);
  sqlite3_free(error);assert(rc==SQLITE_OK);
}
int main(int argc, char **argv) {
  assert(argc==2);
  sqlite3 *writer=NULL,*reader=NULL,*blocker=NULL;
  assert(sqlite3_open(argv[1],&writer)==SQLITE_OK);
  sql(writer,"PRAGMA journal_mode=WAL; CREATE TABLE cache_19(key,value); CREATE TABLE cache_18(key,value); CREATE TABLE keep(value); "
      "INSERT INTO cache_19 VALUES(1,randomblob(200000)); INSERT INTO cache_18 VALUES(1,randomblob(200000)); INSERT INTO keep VALUES(7);");
  assert(sqlite3_open(argv[1],&reader)==SQLITE_OK);
  sql(reader,"BEGIN");assert(wmt_cache_scalar(reader,"SELECT count(*) FROM cache_19")==1);
  struct stat before,after;assert(stat(argv[1],&before)==0);
  assert(wmt_trim_shader_cache(writer,4096)==SQLITE_OK);
  assert(wmt_cache_scalar(writer,"SELECT count(*) FROM cache_19")==0);
  assert(wmt_cache_scalar(writer,"SELECT count(*) FROM cache_18")==0);
  assert(wmt_cache_scalar(reader,"SELECT count(*) FROM cache_19")==1);
  assert(wmt_cache_scalar(writer,"SELECT value FROM keep")==7);
  assert(stat(argv[1],&after)==0 && before.st_ino==after.st_ino);
  sql(reader,"COMMIT");assert(wmt_cache_scalar(reader,"SELECT count(*) FROM cache_19")==0);
  sql(writer,"INSERT INTO cache_19 VALUES(2,randomblob(200000))");
  assert(sqlite3_open(argv[1],&blocker)==SQLITE_OK);sql(blocker,"BEGIN IMMEDIATE");
  assert(wmt_trim_shader_cache(writer,4096)==SQLITE_BUSY);
  assert(wmt_cache_scalar(writer,"SELECT count(*) FROM cache_19")==1);
  sql(blocker,"ROLLBACK");assert(wmt_trim_shader_cache(writer,0)==SQLITE_OK);
  assert(wmt_cache_scalar(writer,"SELECT count(*) FROM cache_19")==1);
  assert(wmt_trim_shader_cache(writer,4096)==SQLITE_OK);
  assert(wmt_cache_scalar(reader,"SELECT count(*) FROM cache_19")==0);
  sqlite3_close(blocker);sqlite3_close(reader);sqlite3_close(writer);
  puts("PASS: SQLite trim preserves live reader snapshots, database inode, unrelated tables and busy writers");
}
