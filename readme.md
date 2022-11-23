# MRD App Interface to FID-A Spectroscopy Toolbox

This repository provides an MRD App interface to the [FID-A Spectroscopy Toolbox](https://github.com/CIC-methods/FID-A).  An example workflow is provided for the [run_megapressproc_auto.m](https://github.com/CIC-methods/FID-A/blob/master/exampleRunScripts/run_megapressproc_auto.m) script.

## Input Data
This app takes as input MEGA-PRESS spectroscopy data with and without water suppression.  All sequences and formats supported by FID-A can be used as input.  The following parameters must be present in the [MRD XML Header](https://ismrmrd.readthedocs.io/en/latest/mrd_header.html):
* ``WaterSaturation`` is a ``userParameterString`` where a value of ``WATER_SUPPRESSION_RF_OFF`` indicates that water suppression is enabled
* ``studyInstanceUID`` is part of the [``studyInformation``](https://github.com/ismrmrd/ismrmrd/blob/d805117b0d2075c8b6c4473eac55b055d2ba9590/schema/ismrmrd.xsd#L46) section, and must be the same between water suppressed and non-suppressed scans.

The following test data sets are provided in the app container at ``/test_data``:
* ``megapressDLPFC.mrd``, an MRD format conversion of [megapressDLPFC.dat](https://github.com/CIC-methods/FID-A/blob/master/exampleData/Siemens/sample01_megapress/megapress/megapressDLPFC.dat)
* ``megapressDLPFC_w.mrd``, an MRD format conversion of [megapressDLPFC_w.dat](https://github.com/CIC-methods/FID-A/blob/master/exampleData/Siemens/sample01_megapress/megapress/megapressDLPFC_w.dat)

## Supported Configurations
This app supports 1 config with a value of ``fida_megapress``, to be called with both water suppressed and unsuppressed data.

## Running the app
The MRD app can be downloaded from Docker Hub at https://hub.docker.com/r/kspacekelvin/fid-a-mrd-app.  In a command prompt on a system with [Docker](https://www.docker.com/) installed, download the Docker image:
```
docker pull kspacekelvin/fid-a-mrd-app
```

Start the Docker image with the container name ``fida-app``, a local folder named ``~/data`` mounted inside the container at ``/data``, and port 9002 shared:
```
docker run --rm --name fida-app -v ~/data:/data -p 9002:9002 kspacekelvin/fid-a-mrd-app
```

In another window, use an MRD client such as the one from the [python-ismrmrd-server](https://github.com/kspaceKelvin/python-ismrmrd-server#11-reconstruct-a-phantom-raw-data-set-using-the-mrd-clientserver-pair).  A copy is included in the app.

Start another terminal inside the Docker started above:
```
docker exec -it fida-app bash
```

Run the client and send the data to the server.  Data must be sent for both the water suppresed and unsuppressed, in separate sessions.
```
python3 /opt/code/python-ismrmrd-server/client.py -c fida_megapress -o /data/megapress_processed_w.mrd /test_data/megapressDLPFC_w.mrd
python3 /opt/code/python-ismrmrd-server/client.py -c fida_megapress -o /data/megapress_processed.mrd /test_data/megapressDLPFC.mrd
```

Data can be sent in either order, although if water-suppressed data is sent first, no FID-A processing is performed until the unsuppressed data is sent.

The output file (e.g. megapress_processed.mrd) contains a single processed spectra calcaulated by FID-A and is stored in the ``~/data`` folder.

When processing is complete, the Docker container can be stopped by running:
```
docker kill fida-app
```

## Building the App
This code is an interface between the [FID-A Spectroscopy Toolbox](https://github.com/CIC-methods/FID-A) and the [matlab-ismrmrd-server](https://github.com/kspaceKelvin/matlab-ismrmrd-server), which implements an MRD App compatible interface using the [MRD](https://github.com/ismrmrd/ismrmrd/) data format.  The server can be run on any MATLAB-supported operating system, but Docker images can only built when running on Linux.

1. Clone (download) the [matlab-ismrmrd-server](https://github.com/kspaceKelvin/matlab-ismrmrd-server) repository.
    ```
    git clone https://github.com/kspaceKelvin/matlab-ismrmrd-server.git
    ```

1. Clone (download) the [FID-A Spectroscopy Toolbox](https://github.com/CIC-methods/FID-A) repository.
    ```
    git clone https://github.com/CIC-methods/FID-A.git
    ```

1. Copy the MATLAB code from the FID-A repository into the main repository.
    ```
    cp -r FID-A/* matlab-ismrmrd-server/
    ```

1. Clone (download) this repository.
    ```
    git clone https://github.com/kspaceKelvin/FID-A-MRD-App.git
    ```

1. Merge the MATLAB code from this repository into the main repository.  Note: the ``server.m`` file will be overwritten.
    ```
    cp FID-A-MRD-App/*.m matlab-ismrmrd-server/
    ```

1. In the MATLAB command prompt, add the ``matlab-ismrmrd-server`` folder and its sub-folders to the path.
    ```
    addpath(genpath('matlab-ismrmrd-server'))
    ```

1. In the MATLAB command prompt, start the server
   ```
   fire_matlab_ismrmrd_server
   ```

1. Send data to the server using the client (see above) to verify the code is correctly installed.

1. Compile the server as a standalone executable and build the Docker image:
    ```  
    res = compiler.build.standaloneApplication('fire_matlab_ismrmrd_server.m', 'TreatInputsAsNumeric', 'on')
    opts = compiler.package.DockerOptions(res, 'ImageName', 'fid-a-mrd-app')
    compiler.package.docker(res, 'Options', opts)
    ```
