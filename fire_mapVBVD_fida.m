classdef fire_mapVBVD_fida < handle
    methods
        function process(obj, connection, config, metadata, logging)
            logging.info('Config: \n%s', config);

            % Metadata should be MRD formatted header, but may be a string
            % if it failed conversion earlier
            try
                logging.info("Incoming dataset contains %d encodings", numel(metadata.encoding))
                logging.info("First encoding is of type '%s', with field of view of (%g x %g x %g)mm^3, matrix size of (%g x %g x %g), and %g coils", ...
                    metadata.encoding(1).trajectory, ...
                    metadata.encoding(1).encodedSpace.fieldOfView_mm.x, ...
                    metadata.encoding(1).encodedSpace.fieldOfView_mm.y, ...
                    metadata.encoding(1).encodedSpace.fieldOfView_mm.z, ...
                    metadata.encoding(1).encodedSpace.matrixSize.x, ...
                    metadata.encoding(1).encodedSpace.matrixSize.y, ...
                    metadata.encoding(1).encodedSpace.matrixSize.z, ...
                    metadata.acquisitionSystemInformation.receiverChannels)
            catch
                logging.info("Improperly formatted metadata: \n%s", metadata)
            end

            % Patch data from siemens_to_ismrmrd that doesn't work with SequenceName
            indSeqName = find(arrayfun(@(x) strcmp(x.name, 'sequenceName'), metadata.userParameters.userParameterString), 1);
            if ~isempty(indSeqName)
                metadata.measurementInformation.sequenceName = metadata.userParameters.userParameterString(indSeqName).value;
            end

            indProName = find(arrayfun(@(x) strcmp(x.name, 'protocolName'), metadata.userParameters.userParameterString), 1);
            if ~isempty(indProName)
                metadata.measurementInformation.protocolName = metadata.userParameters.userParameterString(indProName).value;
            end

            % Continuously parse incoming data parsed from MRD messages
            acqGroup = cell(1,0); % ismrmrd.Acquisition;
            imgGroup = cell(1,0); % ismrmrd.Image;
            wavGroup = cell(1,0); % ismrmrd.Waveform;
            try
                while true
                    item = next(connection);

                    % ----------------------------------------------------------
                    % Raw k-space data messages
                    % ----------------------------------------------------------
                    if isa(item, 'ismrmrd.Acquisition')
                        % Accumulate all imaging readouts in a group
                        if (~item.head.flagIsSet(item.head.FLAGS.ACQ_IS_NOISE_MEASUREMENT)    && ...
                            ~item.head.flagIsSet(item.head.FLAGS.ACQ_IS_PHASECORR_DATA)       && ...
                            ~item.head.flagIsSet(item.head.FLAGS.ACQ_IS_PARALLEL_CALIBRATION)       )
                                acqGroup{end+1} = item;
                        end

                        % When this criteria is met, run process_raw() on the accumulated
                        % data, which returns images that are sent back to the client.
                        if item.head.flagIsSet(item.head.FLAGS.ACQ_LAST_IN_MEASUREMENT)
                            logging.info("Processing a group of k-space data")
                            image = obj.process_raw(acqGroup, config, metadata, logging);
                            logging.debug("Sending image to client")
                            connection.send_image(image);
                            acqGroup = [];
                        end

                    % ----------------------------------------------------------
                    % Image data messages
                    % ----------------------------------------------------------
                    elseif isa(item, 'ismrmrd.Image')
                        % Only process magnitude images -- send phase images back without modification
                        if (item.head.image_type == item.head.IMAGE_TYPE.MAGNITUDE)
                            imgGroup{end+1} = item;
                        else
                            connection.send_image(item);
                            continue
                        end

                        % When this criteria is met, run process_group() on the accumulated
                        % data, which returns images that are sent back to the client.
                        % TODO: logic for grouping images
                        if false
                            logging.info("Processing a group of images")
                            image = obj.process_images(imgGroup, config, metadata, logging);
                            logging.debug("Sending image to client")
                            connection.send_image(image);
                            imgGroup = cell(1,0);
                        end

                    % ----------------------------------------------------------
                    % Waveform data messages
                    % ----------------------------------------------------------
                    elseif isa(item, 'ismrmrd.Waveform')
                        wavGroup{end+1} = item;

                    elseif isempty(item)
                        break;

                    else
                        logging.error("Unhandled data type: %s", class(item))
                    end
                end
            catch ME
                logging.error(sprintf('%s\nError in %s (%s) (line %d)', ME.message, ME.stack(1).('name'), ME.stack(1).('file'), ME.stack(1).('line')));
            end

            % Extract raw ECG waveform data. Basic sorting to make sure that data 
            % is time-ordered, but no additional checking for missing data.
            % ecgData has shape (5 x timepoints)
            if ~isempty(wavGroup)
                isEcg   = cellfun(@(x) (x.head.waveform_id == 0), wavGroup);
                ecgTime = cellfun(@(x) x.head.time_stamp, wavGroup(isEcg));

                [~, sortedInds] = sort(ecgTime);
                indsEcg = find(isEcg);
                ecgData = cell2mat(permute(cellfun(@(x) x.data, wavGroup(indsEcg(sortedInds)), 'UniformOutput', false), [2 1]));
            end

            % Process any remaining groups of raw or image data.  This can 
            % happen if the trigger condition for these groups are not met.
            % This is also a fallback for handling image data, as the last
            % image in a series is typically not separately flagged.
            if ~isempty(acqGroup)
                logging.info("Processing a group of k-space data (untriggered)")
                image = obj.process_raw(acqGroup, config, metadata, logging);
                logging.debug("Sending image to client")
                connection.send_image(image);
                acqGroup = cell(1,0);
            end

            if ~isempty(imgGroup)
                logging.info("Processing a group of images (untriggered)")
                image = obj.process_image(imgGroup, config, metadata, logging);
                logging.debug("Sending image to client")
                connection.send_image(image);
                imgGroup = cell(1,0);
            end

            connection.send_close();
            return
        end

        % Process a set of raw k-space data and return an image
        function mrdFids = process_raw(obj, group, config, metadata, logging)
            tmpDir = '/tmp/share/';
            cacheFile = 'fida-prev.mat';
            if ~exist(tmpDir, 'dir')
                mkdir(tmpDir)
            end

            mrdFids = cell(1,0);

            % This is almost like the twix_obj
            twix_obj = twix_map_obj_fire;
            twix_obj.setMrdAcq(group);

            kspAll = twix_obj.imageData();
            logging.info("Data is 'mapVBVD formatted' with dimensions:")  % Data is 'mapVBVD formatted' with dimensions:
            logging.info(sprintf(' %s ', twix_obj.dataDims{1:12}))         % Col Cha Lin Par Sli Ave Phs Eco Rep Set
            logging.info(sprintf('%4d ', size(kspAll)))                    % 404  14 124   1   1   1   1   1   1  11
            
            % --------- FID-A integration --------------------------------------
            bWaterSat = false;
            indWaterSat = find(arrayfun(@(x) strcmp(x.name, 'WaterSaturation'), metadata.userParameters.userParameterString), 1);
            if (~isempty(indWaterSat) && strcmp(metadata.userParameters.userParameterString(indWaterSat).value, 'WATER_SUPPRESSION_RF_OFF')) || (metadata.measurementInformation.protocolName(end) == 'w')
                bWaterSat = true;
            end

            % Format the incoming dataset
            if bWaterSat
                logging.info("Incoming dataset IS water saturated")
                out_w = io_loadspec_fire(kspAll, metadata, twix_obj);
            else
                logging.info("Incoming dataset IS NOT water saturated")
                out = io_loadspec_fire(kspAll, metadata, twix_obj);
            end

            % Check to see if a previous dataset exists
            if exist(fullfile(tmpDir, cacheFile), 'file')
                logging.info("Found previous dataset")
                w = who('-file', fullfile(tmpDir, cacheFile));
                if ismember('out_w', w) && bWaterSat
                    logging.info("Previous dataset and current dataset are both water saturated -- not loading previous data")
                elseif ismember('out', w) && ~bWaterSat
                    logging.info("Previous dataset and current dataset are both not water saturated -- not loading previous data")
                elseif ismember('out_w', w) && ~bWaterSat
                    logging.info("Loading water suppresed data from previous dataset")
                    load(fullfile(tmpDir, cacheFile))
                elseif ismember('out', w) && bWaterSat
                    logging.info("Loading non-water suppresed data from previous dataset")
                    load(fullfile(tmpDir, cacheFile))
                end

                % Check to see if loaded data is from the same study
                if exist('out', 'var') && exist('out_w', 'var')
                    if strcmp(out.studyInstanceUID, out_w.studyInstanceUID)
                        logging.info("Verified that current and previous dataset are from same study -- proceeding")
                    else
                        if bWaterSat
                            logging.error(sprintf("Current dataset and previous dataset have different studyInstanceUIDs (%s vs %s) -- not using previous data", out_w.studyInstanceUID, out.studyInstanceUID))
                            clear out
                        else
                            logging.error(sprintf("Current dataset and previous dataset have different studyInstanceUIDs (%s vs %s) -- not using previous data", out.studyInstanceUID, out_w.studyInstanceUID))
                            clear out_w
                        end
                    end
                end
            else
                logging.info("Did not find cached previous dataset")
            end

            % Save cache of current data
            if bWaterSat
                save(fullfile(tmpDir, cacheFile), 'out_w');
            else
                save(fullfile(tmpDir, cacheFile), 'out');
            end

            if ~exist('out', 'var')
                logging.warning("Only water suppressed data available -- storing data for subsequent processing with unsuppressed data")
                return
            end

            warning('off', 'MATLAB:plot:IgnoreImaginaryXYPart')

            if exist('out_w', 'var')
                [diffSpec,sumSpec,subSpec1,subSpec2,outWatUnSup] = fire_run_megapressproc_auto(out, out_w);
            else
                [diffSpec,sumSpec,subSpec1,subSpec2,outWatUnSup] = fire_run_megapressproc_auto(out, []);
            end


            fids  = {diffSpec.fids, sumSpec.fids, subSpec1.fids, subSpec2.fids};
            names = {'DIFF',        'SUM',        'EDIT_OFF',    'EDIT_ON'};

            if isstruct(outWatUnSup)
                fids{end+1} = outWatUnSup.fids;
                names{end+1} = 'WATER_UNSUPPRESSED';
            end

            % Determine if oversampling removal is selected
            indRemoveOversample = find(arrayfun(@(x) strcmp(x.name, 'SpecRemoveOversampling'), metadata.userParameters.userParameterLong), 1);
            if metadata.userParameters.userParameterLong(indRemoveOversample).value ~= 0
                bRemoveOversample = true;
            else
                bRemoveOversample = false;
            end

            mrdFids = {};
            for iFid = 1:numel(fids)
                if bRemoveOversample
                    n = numel(fids{iFid});
                    indsKeep = [(n/4+1):(n*3/4)];
                    tmpSpec = fftshift(ifft(fftshift(fids{iFid}       ,1),[],1),1);
                    tmpFid  = fftshift(fft( fftshift(tmpSpec(indsKeep),1),[],1),1);
                else
                    tmpFid = fids{iFid};
                end

                % Format as ISMRMRD image data
                mrdFid = ismrmrd.Image(tmpFid);

                % Copy the relevant AcquisitionHeader fields to ImageHeader
                mrdFid.head = mrdFid.head.fromAcqHead(group{1}.head);

                % field_of_view is mandatory
                % Not sure why y doesn't account for oversampling. x is a crazy number to keep "square pixels".
                mrdFid.head.field_of_view  = single([numel(tmpFid)*metadata.encoding(1).reconSpace.fieldOfView_mm.y/2 ...
                                                                    metadata.encoding(1).reconSpace.fieldOfView_mm.y/2 ...
                                                                    metadata.encoding(1).reconSpace.fieldOfView_mm.z]);

                % Reset the DimBoundaries of averages to 1
                mrdFid.head.flags = 2^(ismrmrd.ImageHeader.FLAGS.IMAGE_LAST_IN_AVERAGE-1);

                % Set ISMRMRD Meta Attributes
                meta = struct;
                meta.DataRole                           = 'Spectroscopy';
                meta.ImageProcessingHistory             = 'FIDA';
                meta.Keep_Image_Geometry                = 1;
                meta.SiemensControl_SpectroData         = {'bool', 'true'};
                meta.SiemensControl_Suffix4DataFileName = {'string', '-1_1_1_1_1_1'};

                meta.ImageRowDir            = group{1}.head.read_dir;
                meta.ImageColumnDir         = group{1}.head.phase_dir;

                % Separate each FID into a separate series with description
                mrdFid.head.image_series_index = iFid;
                meta.SequenceDescriptionAdditional = names{iFid};

                % set_attribute_string also updates attribute_string_len
                mrdFid = mrdFid.set_attribute_string(ismrmrd.Meta.serialize(meta));

                mrdFids{end+1} = mrdFid;
            end
            logging.info(sprintf('Processed %d spectra', numel(mrdFids)))
        end

        % Placeholder function that returns images without modification
        function images = process_images(obj, group, config, metadata, logging)
            images = group;
        end
    end
end
