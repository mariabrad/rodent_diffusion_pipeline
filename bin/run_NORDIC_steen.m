function x = run_NORDIC_new(magnPath, phasePath, oPath, name, domain, kernelsize)
    % Add directory containing this script to MATLAB path
    thisDir = fileparts(mfilename('fullpath'));
    addpath(thisDir);
    
    % Check required dependencies
    required = {
        'NIFTI_NORDIC_steen'
        'niftiinfo'
        'niftiread'
        'niftiwrite'
        'tukeywin'
    };

    for i = 1:numel(required)
        if isempty(which(required{i}))
            error('Required MATLAB function not found: %s', required{i});
        end
    end

    % Initialize ARG
    ARG = struct();
    %ARG.use_magn_for_gfactor = 1;
    %ARG.factor_error = sqrt(2);            % sqrt(2) due to complex signal
    %ARG.MP = 1;
    %ARG.gfactor_patch_overlap=3; % To make noisemap less blocky - By default is 2
    ARG.save_add_info = 1;
    ARG.write_gzipped_niftis = 1;
    % Define output name and print inputs
    fn_out = name;
    ARG.DIROUT = oPath;

    % Set domain mode
    if strcmp(domain, 'complex')
        disp('Domain: complex')
        %ARG.magnitude_only = [];
    	ARG.temporal_phase = 3;                % Default for dMRI - Change to 1 for CMRR sequences
    	ARG.phase_filter_width = 3;
    
    elseif strcmp(domain, 'mag')
        disp('Domain: mag')
        ARG.magnitude_only = 1;
    else
        error('Invalid domain value: %s', domain);
    end

    % Set kernel size if provided
    if ~isempty(kernelsize)
        kernelsize = str2double(kernelsize);
        ARG.kernel_size_PCA = repmat(kernelsize, 1, 3);
    end

    
    % Run NORDIC
    NIFTI_NORDIC_steen(magnPath, phasePath, fn_out, ARG);

    disp('NORDIC finished successfully');
    x = 1;
end
