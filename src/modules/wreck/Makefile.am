AM_CFLAGS = @GCCWARN@

AM_CPPFLAGS = \
	$(JSON_CFLAGS) \
	-I$(top_srcdir) \
	-I$(top_srcdir)/src/include \
	-I$(top_srcdir)/src/common/libmrpc \
	-I$(top_srcdir)/src/common/libflux \
	-I$(top_srcdir)/src/common/liblsd \
	-I$(top_srcdir)/src/modules/broker \
	-I$(top_srcdir)/src/modules/kvs \
	-I$(top_srcdir)/src/broker \
	-DWREXECD_BINDIR=\"$(libexecdir)/flux\" \
	-DWRECK_LUA_PATTERN=\"$(sysconfdir)/wreck/lua.d/*.lua\"

libfluxdir = $(libdir)/flux
fluxmoddir = $(libfluxdir)/modules
fluxbindir = $(libexecdir)/flux
includefluxcoredir = $(includedir)/flux/core
wreckscriptsdir = $(sysconfdir)/wreck/lua.d

#
# Comms module
#
fluxmod_LTLIBRARIES = \
	job.la \
	resrc.la \
	wrexecinst.la

noinst_LTLIBRARIES = \
	wrexec.la

fluxbin_PROGRAMS = \
	wrexecd

fluxmod_libadd = \
	$(top_builddir)/src/common/libmrpc/libmrpc.la \
	$(top_builddir)/src/modules/kvs/libkvs.la \
	$(top_builddir)/src/common/libflux/libflux.la \
	$(top_builddir)/src/common/libutil/libutil.la \
	$(top_builddir)/src/common/liblsd/liblsd.la \
	$(JSON_LIBS) $(LIBZMQ) $(LIBCZMQ)

fluxmod_ldflags = -avoid-version -module -shared -export-dynamic \
	-export-symbols-regex '^mod_(main|name)$$' -rpath  /dev/null

job_la_SOURCES = job.c
job_la_LDFLAGS = $(fluxmod_ldflags)
job_la_LIBADD = $(fluxmod_libadd)

wrexec_la_SOURCES = wrexec.c
wrexec_la_LDFLAGS = $(fluxmod_ldflags)
wrexec_la_LIBADD = $(fluxmod_libadd)
wrexec_la_CPPFLAGS = $(AM_CPPFLAGS) -DWREXECD_PATH=\"$(abs_builddir)/wrexecd\"

wrexecinst_la_SOURCES = wrexec.c
wrexecinst_la_LDFLAGS = $(fluxmod_ldflags)
wrexecinst_la_LIBADD = $(fluxmod_libadd)
wrexecinst_la_CPPFLAGS = $(AM_CPPFLAGS) -DWREXECD_PATH=\"$(fluxbindir)/wrexecd\"

resrc_la_SOURCES = resrc.c
resrc_la_LDFLAGS = $(fluxmod_ldflags)
resrc_la_LIBADD = $(fluxmod_libadd)

wrexecd_SOURCES = \
	wrexecd.c \
	luastack.c \
	luastack.h

wrexecd_LDADD = \
	$(top_builddir)/src/bindings/lua/libfluxlua.la \
	$(top_builddir)/src/common/libzio/libzio.la \
	$(top_builddir)/src/common/libflux/libflux.la \
	$(top_builddir)/src/common/libmrpc/libmrpc.la \
	$(top_builddir)/src/modules/api/libapi.la \
	$(top_builddir)/src/modules/kvs/libkvs.la \
	$(top_builddir)/src/common/liblsd/liblsd.la \
	$(top_builddir)/src/common/libutil/libutil.la \
	$(JSON_LIBS) $(LIBZMQ) $(LIBCZMQ) $(LUA_LIB)

dist_wreckscripts_SCRIPTS = \
	lua.d/01-env.lua

install-data-hook:
	-(cd $(DESTDIR)$(fluxmoddir) && \
	  for f in wrexecinst*; do \
	    mv $$f `echo $$f | sed 's/inst//'`; \
	  done;)

uninstall-hook:
	-(cd $(DESTDIR)$(fluxmoddir) && \
	  rm -f wrexec.so wrexec.la )
	

# XXX: Hack below to force rebuild of unbuilt wrexecd dependencies
#
$(wrexecd_LDADD):
	@cd `dirname $@` && $(MAKE) `basename $@`