FROM docker.io/alpine:edge AS source
RUN wget --no-verbose https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.7.9.tar.gz
RUN wget --no-verbose https://musl.libc.org/releases/musl-1.2.5.tar.gz
RUN wget --no-verbose https://www.zlib.net/zlib-1.3.1.tar.gz
RUN wget --no-verbose https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.1/llvm-project-18.1.1.src.tar.xz
RUN wget --no-verbose https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2

FROM ghcr.io/clangbuiltlinux/llvm-project:stage2-x86_64 AS base

FROM docker.io/alpine:edge AS sysroot

COPY --from=base /usr/local/bin /usr/local/bin
COPY --from=base /usr/local/lib /usr/local/lib
COPY --from=base /usr/local/include /usr/local/include
RUN cd /usr/lib/ && \
  for library in libc++abi.so.1 libc++.a libc++abi.a libc++.so.1 libunwind.so.1 libunwind.a; \
    do ln -s "/usr/local/lib/$(uname -m)-alpine-linux-musl/${library}" . ; \
  done

COPY --from=source linux-6.7.9.tar.gz .
RUN tar xf linux-6.7.9.tar.gz
RUN apk add make musl-dev rsync
RUN make -C linux-5.18-rc6 INSTALL_HDR_PATH=/sysroot/usr LLVM=1 -j$(nproc) headers_install
RUN apk del rsync musl-dev make

### Musl
COPY --from=source musl-1.2.5.tar.gz .
RUN tar xf musl-1.2.5.tar.gz
ARG MUSL_DIR=musl-1.2.5/build
RUN mkdir -p ${MUSL_DIR}
RUN cd ${MUSL_DIR} && \
  CC=clang AR=llvm-ar RANLIB=llvm-ranlib \
  ../configure --prefix=/usr --syslibdir=/usr/lib
RUN apk add make
RUN make -C ${MUSL_DIR} -j$(nproc)
RUN make -C ${MUSL_DIR} -j$(nproc) DESTDIR=/sysroot install-headers
RUN make -C ${MUSL_DIR} -j$(nproc) DESTDIR=/sysroot install-libs
RUN apk del make

### Zlib
COPY --from=source zlib-1.3.1.tar.gz .
RUN tar xf zlib-1.3.1.tar.gz
ARG ZLIB_DIR=zlib-1.3.1/build
RUN mkdir -p ${ZLIB_DIR}
RUN cd ${ZLIB_DIR} && \
  CC="clang ${SYSROOT}" AR=llvm-ar ../configure --prefix=/sysroot/usr
RUN apk add make
RUN make -C ${ZLIB_DIR} -j$(nproc)
RUN make -C ${ZLIB_DIR} -j$(nproc) install
RUN apk del make

### Jemalloc
COPY --from=source jemalloc-5.3.0.tar.bz2 .
RUN tar xf jemalloc-5.3.0.tar.bz2
ARG JEMALLOC_DIR=jemalloc-5.3.0/build
RUN mkdir -p ${JEMALLOC_DIR}
RUN cd ${JEMALLOC_DIR} && \
  CC=clang AR=llvm-ar NM=llvm-nm CPPFLAGS=${SYSROOT} LDFLAGS=${SYSROOT} \
  ../configure --disable-libdl --prefix=/usr
RUN apk add make
RUN make -C ${JEMALLOC_DIR} -j$(nproc) build_lib_static
RUN make -C ${JEMALLOC_DIR} -j$(nproc) DESTDIR=/sysroot install_lib_static
RUN apk del make

### LLVM
COPY --from=source llvm-project-18.1.1.src.tar.xz .
RUN tar xf llvm-project-18.1.1.src.tar.xz && \
  mv llvm-project-18.1.1.src llvm-project
RUN apk add cmake ninja python3
COPY stage3.cmake llvm-project/.
COPY 0001-libc-Fix-build-when-__FE_DENORM-is-defined.patch llvm-project/.
RUN apk add patch
RUN cd llvm-project && \
  patch -p1 < 0001-libc-Fix-build-when-__FE_DENORM-is-defined.patch
RUN apk del patch
ARG LLVM_BUILD_DIR=llvm-project/llvm/build
RUN cmake \
  -B ${LLVM_BUILD_DIR} \
  -C llvm-project/stage3.cmake \
  -D LLVM_DEFAULT_TARGET_TRIPLE=$(clang -print-target-triple) \
  -S llvm-project/llvm \
  -G Ninja

RUN ninja -C ${LLVM_BUILD_DIR} llvmlibc
COPY build_sparse_libc.sh ${LLVM_BUILD_DIR}/.
RUN cd ${LLVM_BUILD_DIR} && \
  ./build_sparse_libc.sh && \
  mv libllvmlibc-sparse.a /sysroot/usr/lib/.