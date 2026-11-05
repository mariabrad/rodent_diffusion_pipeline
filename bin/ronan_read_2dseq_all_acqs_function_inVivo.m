function ronan_read_2dseq_all_acqs_function_inVivo(RAW_DIR, OUTDIR, DIR_NAMES, FOLDER_NO, COMPLEX_RECON_FOLDER_NUMBER, ACQ_DIM)
    % Ensure functions stored alongside this script are visible
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);

    % Check required custom dependency
    if isempty(which('read_2dseq'))
        error('Required function read_2dseq.m not found in %s', thisDir);
    end
    
    % Collect everything for the final all_shells output
    all_mag_cells = {};
    all_pha_cells = {};
    all_order = {};
    %% 

    for idx = 1:length(FOLDER_NO)
        folder_no = FOLDER_NO(idx);
        dir_name = DIR_NAMES{idx};
        complex_folder_no = COMPLEX_RECON_FOLDER_NUMBER(idx);

        % Construct the data path
        data_folder = sprintf('%d', folder_no);
        data_path = fullfile(RAW_DIR, data_folder, 'pdata', num2str(complex_folder_no));
        fprintf('=Â Reading data from: %s\n', data_path);

		% Read and reshape data
        data_mouse = double(read_2dseq(data_path));
		fprintf('Original data size: [%s]\n', num2str(size(data_mouse)));
        fprintf('Expected input: [Nro, Npe, junk, junk, Nslice, Nvols, Nreps, Nch]\n');

        sz = size(data_mouse);

        Nro   = sz(1);
        Npe   = sz(2);
        Nvols = sz(6);
        Nreps = sz(7);
        Nch   = sz(8);

        % Handle 2D and 3D acquisition layouts explicitly.
        if strcmpi(ACQ_DIM, '2D')

            % Expected 2D layout:
            % [Nro, Npe, junk, junk, Nslice, Nvols, Nreps, Nch]

            Nslice = sz(5);

            data_mouse = reshape( ...
                data_mouse, ...
                Nro, Npe, Nslice, Nvols, Nreps, Nch);

        elseif strcmpi(ACQ_DIM, '3D')

            % Expected 3D layout:
            % [Nro, Npe, N3, junk, junk, Nvols, Nreps, Nch]

            Nslice = sz(3);

            data_mouse = reshape( ...
                data_mouse, ...
                Nro, Npe, Nslice, Nvols, Nreps, Nch);

        else

            error('Unsupported acquisition dimensionality: %s. Expected 2D or 3D.', ACQ_DIM);

        end

        fprintf('Raw data dimensions: [%s]\n', num2str(sz));
        fprintf('Acquisition dimensionality: %s\n', ACQ_DIM);
        fprintf('Standardized size: [%d %d %d %d %d %d]\n', ...
            Nro, Npe, Nslice, Nvols, Nreps, Nch);
        fprintf('Detected total_volumes = %d\n', Nvols);

        % Process each repetition separately
        for rep_idx = 1:Nreps
            fprintf('= Processing rep %d of %d for shell %s\n', rep_idx, Nreps, dir_name);
            mag_data = zeros(Nro, Npe, Nslice, Nvols, Nch);
            pha_data = zeros(Nro, Npe, Nslice, Nvols, Nch);
            mag_sum = zeros(Nro, Npe, Nslice, Nvols);
            phs_sum = zeros(Nro, Npe, Nslice, Nvols);
            for j = 1:Nvols
                for k = 1:Nch
                    vol = data_mouse(:,:,:,j,rep_idx,k);                    
					mag_data(:,:,:,j,k) = abs(vol);
                    pha_data(:,:,:,j,k) = angle(vol);
                end

                mag_sum(:,:,:,j) = sqrt(sum(abs(mag_data(:,:,:,j,:)).^2, 5));
                phs_sum(:,:,:,j) = angle(sum(mag_data(:,:,:,j,:) .* exp(1i * pha_data(:,:,:,j,:)), 5));
            end

            % Output path
            outPath = fullfile(OUTDIR, dir_name);
            if ~exist(outPath, 'dir'); mkdir(outPath); end

            % Save each rep separately
            mag_fname = fullfile(outPath, sprintf('mag_sum_rep%d.nii.gz', rep_idx));
            pha_fname = fullfile(outPath, sprintf('pha_sum_rep%d.nii.gz', rep_idx));
            
            niftiwrite(mag_sum, mag_fname, 'Compressed', true);
            niftiwrite(phs_sum, pha_fname, 'Compressed', true);
            fprintf(' Saved rep %d: %s\n', rep_idx, mag_fname);

            all_mag_cells{end+1} = mag_sum;
            all_pha_cells{end+1} = phs_sum;

            for j = 1:Nvols
                all_order{end+1} = sprintf('%s / rep%d / vol%d', dir_name, rep_idx, j);
            end
        end
    end
    % Build the combined all_shells outputs
    all_shells_mag_sum = cat(4, all_mag_cells{:});
    all_shells_pha_sum = cat(4, all_pha_cells{:});

    allShellsPath = fullfile(OUTDIR, 'all_shells');
    if ~exist(allShellsPath, 'dir')
        mkdir(allShellsPath);
    end

    % Print the volume order
    fprintf('\nOrder of volumes in all_shells_combined_mag_sum / all_shells_combined_pha_sum:\n');
    for i = 1:numel(all_order)
        fprintf('%4d: %s\n', i, all_order{i});
    end

    all_mag_fname = fullfile(allShellsPath, 'all_shells_combined_mag_sum.nii.gz');
    all_pha_fname = fullfile(allShellsPath, 'all_shells_combined_pha_sum.nii.gz');

    niftiwrite(all_shells_mag_sum, all_mag_fname, 'Compressed', true);
    niftiwrite(all_shells_pha_sum, all_pha_fname, 'Compressed', true);

    % Also save the order as a text file
    orderFile = fullfile(allShellsPath, 'all_shells_volume_order.txt');
    fid = fopen(orderFile, 'w');
    for i = 1:numel(all_order)
        fprintf(fid, '%d\t%s\n', i, all_order{i});
    end
    fclose(fid);

    fprintf('\nAll reconstructions complete.\n');
end