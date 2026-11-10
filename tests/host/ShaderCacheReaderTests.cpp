#include <atomic>
#include <cassert>
#include <mutex>
#include <thread>
#include <vector>
#include <string>
#include <cstdio>
static thread_local int readerLocks=0;
namespace dxmt { struct mutex {
  std::mutex value;
  void lock() { value.lock();++readerLocks; }
  void unlock() { --readerLocks;value.unlock(); }
}; }
namespace WMT { struct CacheReader {
  bool present=false;
  operator bool() const { assert(readerLocks>0);return present; }
  static CacheReader alloc_init(const char *,uint64_t) { assert(readerLocks>0);return {true}; }
}; }
using WMTMetalVersion=int;
class ShaderCache {
public:
  template<class T> class LockProtected {
  public:
    LockProtected(dxmt::mutex &mutex,T object,std::adopt_lock_t):object(object),mutex_(&mutex) {}
    LockProtected():object({}),mutex_(nullptr) {}
    ~LockProtected(){if(mutex_)mutex_->unlock();}
    LockProtected(const LockProtected&)=delete;
    operator bool()const{return mutex_!=nullptr;}
    T object;
  private: dxmt::mutex *mutex_;
  };
/* ACTUAL_READER_METHODS */
private:
  WMT::CacheReader scache_reader_;
  dxmt::mutex scache_reader_mutex_;
  std::string cache_path_="shaders.db";
  uint64_t cache_version_=19;
  std::atomic<bool> reader_retry_{false};
};
int main(){
  ShaderCache cache;
  {auto reader=cache.getReader();assert(!reader);}
  cache.noteWritten();
  std::vector<std::thread> workers;
  for(int n=0;n<8;n++) workers.emplace_back([&]{
    for(int i=0;i<10000;i++){
      if(i%2)cache.noteWritten();
      auto reader=cache.getReader();assert(reader && reader.object);
    }
  });
  for(auto &worker:workers)worker.join();
  puts("PASS: actual cache reader methods keep pointer accesses locked across concurrent retries and writes");
}
