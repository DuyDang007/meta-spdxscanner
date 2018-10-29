# This class integrates real-time license scanning, generation of SPDX standard
# output and verifiying license info during the building process.
# It is a combination of efforts from the OE-Core, SPDX and DoSOCSv2 projects.
#
# For more information on DoSOCSv2:
#   https://github.com/DoSOCSv2
#
# For more information on SPDX:
#   http://www.spdx.org
#
# Note:
# 1) Make sure DoSOCSv2 has beed installed in your host
# 2) By default,spdx files will be output to the path which is defined as[SPDX_DEPLOY_DIR] 
#    in ./meta/conf/spdx-dosocs.conf.

SPDXSSTATEDIR = "${WORKDIR}/spdx_sstate_dir"
LICENSELISTVERSION = "2.6"
CREATOR_TOOL = "meta-spdxscanner"
# If ${S} isn't actually the top-level source directory, set SPDX_S to point at
# the real top-level directory.

SPDX_S ?= "${S}"

python do_spdx () {
    import os, sys
    import json

    import shutil

    pn = d.getVar('PN')
    workdir_tmp = d.getVar('WORKDIR')

    ## It's no necessary to get spdx files for *-native
    if pn.find("-native") != -1 or pn.find("binutils-cross") != -1:
        return None

    # Forcibly expand the sysroot paths as we're about to change WORKDIR
    d.setVar('RECIPE_SYSROOT', d.getVar('RECIPE_SYSROOT'))
    d.setVar('RECIPE_SYSROOT_NATIVE', d.getVar('RECIPE_SYSROOT_NATIVE'))

    ## gcc and kernel is too big to get spdx file.
    if ('gcc') in d.getVar('PN', True):
        #invoke_dosocs2("/yocto/work002/fnst/leimh/community/gcc-7.3.0/","/yocto/work001/gcc-7.3.spdx",(d.getVar('WORKDIR', True) or ""))
        return None
    if bb.data.inherits_class('kernel', d):
        #invoke_dosocs2("/yocto/work002/fnst/leimh/community/linux-4.14.44","/yocto/work001/linux-4.14.44.spdx",(d.getVar('WORKDIR', True) or ""))
        return None

    bb.note('Archiving the configured source...')
    # "gcc-source-${PV}" recipes don't have "do_configure"
    # task, so we need to run "do_preconfigure" instead
    if pn.startswith("gcc-source-"):
        d.setVar('WORKDIR', d.getVar('ARCHIVER_WORKDIR'))
        bb.build.exec_func('do_preconfigure', d)

    # Change the WORKDIR to make do_configure run in another dir.
    d.setVar('WORKDIR', d.getVar('SPDX_TEMP_DIR'))
    #if bb.data.inherits_class('kernel-yocto', d):
    #    bb.build.exec_func('do_kernel_configme', d)
    #if bb.data.inherits_class('cmake', d):
    #    bb.build.exec_func('do_generate_toolchain_file', d)
    bb.build.exec_func('do_unpack', d)
  
    d.setVar('WORKDIR', workdir_tmp)
    info = {} 
    info['workdir'] = (d.getVar('WORKDIR', True) or "")
    info['pn'] = (d.getVar( 'PN', True ) or "")
    info['pv'] = (d.getVar( 'PV', True ) or "")
    info['package_download_location'] = (d.getVar( 'SRC_URI', True ) or "")
    if info['package_download_location'] != "":
        info['package_download_location'] = info['package_download_location'].split()[0]
    info['spdx_version'] = (d.getVar('SPDX_VERSION', True) or '')
    info['data_license'] = (d.getVar('DATA_LICENSE', True) or '')
    info['creator'] = {}
    info['creator']['Tool'] = (d.getVar('CREATOR_TOOL', True) or '')
    info['license_list_version'] = (d.getVar('LICENSELISTVERSION', True) or '')
    info['package_homepage'] = (d.getVar('HOMEPAGE', True) or "")
    info['package_summary'] = (d.getVar('SUMMARY', True) or "")
    info['package_summary'] = info['package_summary'].replace("\n","")
    info['package_summary'] = info['package_summary'].replace("'"," ")
    info['package_contains'] = (d.getVar('CONTAINED', True) or "")
    info['package_static_link'] = (d.getVar('STATIC_LINK', True) or "")

    spdx_sstate_dir = (d.getVar('SPDXSSTATEDIR', True) or "")
    manifest_dir = (d.getVar('SPDX_DEPLOY_DIR', True) or "")
    info['outfile'] = os.path.join(manifest_dir, info['pn'] + "-" + info['pv'] + ".spdx" )
    sstatefile = os.path.join(spdx_sstate_dir, 
        info['pn'] + "-" + info['pv'] + ".spdx" )

    ## get everything from cache.  use it to decide if 
    ## something needs to be rerun
    if not os.path.exists( spdx_sstate_dir ):
        bb.utils.mkdirhier( spdx_sstate_dir )
    
    d.setVar('WORKDIR', d.getVar('SPDX_TEMP_DIR', True))
    info['sourcedir'] = (d.getVar('SPDX_S', True) or "")
    cur_ver_code = get_ver_code( info['sourcedir'] ).split()[0]
    cache_cur = False
    if os.path.exists( sstatefile ):
        ## cache for this package exists. read it in
        cached_spdx = get_cached_spdx( sstatefile )
        if cached_spdx:
            cached_spdx = cached_spdx.split()[0]
        if (cached_spdx == cur_ver_code):
            bb.warn(info['pn'] + "'s ver code same as cache's. do nothing")
            cache_cur = True
            create_manifest(info,sstatefile)
    if not cache_cur:
        git_path = "%s/.git" % info['sourcedir']
        if os.path.exists(git_path):
            remove_dir_tree(git_path)

        ## Get spdx file
        #bb.warn(' run_dosocs2 ...... ')
        invoke_dosocs2(info['sourcedir'],sstatefile,info['workdir'])
        if get_cached_spdx( sstatefile ) != None:
            write_cached_spdx( info,sstatefile,cur_ver_code )
            ## CREATE MANIFEST(write to outfile )
            create_manifest(info,sstatefile)
        else:
            bb.warn('Can\'t get the spdx file ' + info['pn'] + '. Please check your dosocs2.')
    d.setVar('WORKDIR', info['workdir'])
}

addtask spdx after do_patch before do_configure

def invoke_dosocs2( OSS_src_dir, spdx_file, workdir):
    import subprocess
    import string
    import json
    import codecs

    
    dosocs2_cmd = "/usr/local/bin/dosocs2"
    dosocs2_oneshot_cmd = dosocs2_cmd + " oneshot " + OSS_src_dir
    print(dosocs2_oneshot_cmd)
    try:
        dosocs2_output = subprocess.check_output(dosocs2_oneshot_cmd,
                                                 stderr=subprocess.STDOUT,
                                                 shell=True)
    except subprocess.CalledProcessError as e:
        bb.warn("Could not invoke dosocs2 oneshot Command "
                 "'%s' returned %d:\n%s" % (dosocs2_oneshot_cmd, e.returncode, e.output))
        return None
    dosocs2_output = dosocs2_output.decode('utf-8')

    f = codecs.open(spdx_file,'w','utf-8')
    f.write(dosocs2_output)

def create_manifest(info,sstatefile):
    import shutil
    shutil.copyfile(sstatefile,info['outfile'])

def get_cached_spdx( sstatefile ):
    import subprocess

    if not os.path.exists( sstatefile ):
        return None
    
    try:
        output = subprocess.check_output(['grep', "PackageVerificationCode", sstatefile])
    except subprocess.CalledProcessError as e:
        bb.error("Index creation command '%s' failed with return code %d:\n%s" % (e.cmd, e.returncode, e.output))
        return None
    cached_spdx_info=output.decode('utf-8').split(': ')
    return cached_spdx_info[1]

## Add necessary information into spdx file
def write_cached_spdx( info,sstatefile, ver_code ):
    import subprocess

    def sed_replace(dest_sed_cmd,key_word,replace_info):
        dest_sed_cmd = dest_sed_cmd + "-e 's#^" + key_word + ".*#" + \
            key_word + replace_info + "#' "
        return dest_sed_cmd

    def sed_insert(dest_sed_cmd,key_word,new_line):
        dest_sed_cmd = dest_sed_cmd + "-e '/^" + key_word \
            + r"/a\\" + new_line + "' "
        return dest_sed_cmd

    ## Document level information
    sed_cmd = r"sed -i -e 's#\r$##g' " 
    spdx_DocumentComment = "<text>SPDX for " + info['pn'] + " version " \ 
        + info['pv'] + "</text>"
    sed_cmd = sed_replace(sed_cmd,"DocumentComment",spdx_DocumentComment)
    
    ## Creator information
    sed_cmd = sed_replace(sed_cmd,"Creator: ",info['creator']['Tool'])
    sed_cmd = sed_replace(sed_cmd,"LicenseListVersion: ",info['license_list_version'])

    ## Package level information
    sed_cmd = sed_replace(sed_cmd,"PackageName: ",info['pn'])
    sed_cmd = sed_insert(sed_cmd,"PackageName: ", "PackageVersion: " + info['pv'])
    sed_cmd = sed_replace(sed_cmd,"PackageDownloadLocation: ",info['package_download_location'])
    sed_cmd = sed_replace(sed_cmd,"PackageHomePage: ",info['package_homepage'])
    sed_cmd = sed_replace(sed_cmd,"PackageSummary: ","<text>" + info['package_summary'] + "</text>")
    sed_cmd = sed_insert(sed_cmd,"PackageVerificationCode: ",ver_code)
    sed_cmd = sed_replace(sed_cmd,"PackageDescription: ", 
        "<text>" + info['pn'] + " version " + info['pv'] + "</text>")
    for contain in info['package_contains'].split( ):
        sed_cmd = sed_insert(sed_cmd,"PackageComment:"," \\n\\n## Relationships\\nRelationship: " + info['pn'] + " CONTAINS " + contain)
    for static_link in info['package_static_link'].split( ):
        sed_cmd = sed_insert(sed_cmd,"PackageComment:"," \\n\\n## Relationships\\nRelationship: " + info['pn'] + " STATIC_LINK " + static_link)
    sed_cmd = sed_cmd + sstatefile

    subprocess.call("%s" % sed_cmd, shell=True)

def remove_dir_tree( dir_name ):
    import shutil
    try:
        shutil.rmtree( dir_name )
    except:
        pass

def remove_file( file_name ):
    try:
        os.remove( file_name )
    except OSError as e:
        pass

def list_files( dir ):
    for root, subFolders, files in os.walk( dir ):
        for f in files:
            rel_root = os.path.relpath( root, dir )
            yield rel_root, f
    return

def hash_file( file_name ):
    """
    Return the hex string representation of the SHA1 checksum of the filename
    """
    try:
        import hashlib
    except ImportError:
        return None
    
    sha1 = hashlib.sha1()
    with open( file_name, "rb" ) as f:
        for line in f:
            sha1.update(line)
    return sha1.hexdigest()

def hash_string( data ):
    import hashlib
    sha1 = hashlib.sha1()
    sha1.update( data.encode('utf-8') )
    return sha1.hexdigest()

def get_ver_code( dirname ):
    chksums = []
    for f_dir, f in list_files( dirname ):
        try:
            stats = os.stat(os.path.join(dirname,f_dir,f))
        except OSError as e:
            bb.warn( "Stat failed" + str(e) + "\n")
            continue
        chksums.append(hash_file(os.path.join(dirname,f_dir,f)))
    ver_code_string = ''.join( chksums ).lower()
    ver_code = hash_string( ver_code_string )
    return ver_code
