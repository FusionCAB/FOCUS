/**
 * Read input.gacode file format
 * 
 * Official documentation here: https://gacode.io/input_gacode.html
 */

#if !defined(FOCUS_INCLUDE_FORMATS_INPUT_GACODE_HPP)
#define FOCUS_INCLUDE_FORMATS_INPUT_GACODE_HPP

#include <fstream>
#include <iostream>
#include <string>
#include <sstream>
#include <regex>
#include <vector>

#include "formats/regex_tokenizer.hpp"
#include "types/plasma.hpp"

Plasma read_input_gacode(std::string filename, std::vector<std::string>& species_identifiers, bool negative_psi = true){
	std::ifstream fi(filename);
	if(!fi.is_open()){
		std::cerr << "Couldn't open file " << filename << '\n';
		RETURN_FAIL: return Plasma(-1, 0, 0);
	}

	int shot = -1;
	int nexp = -1, nion = -1;

	Tokenizer<std::ifstream> tk("[+-]?\\d*[\\.]?\\d+(?:[Ee][+-]?\\d+)?"); // captures any number;
	
	std::string line, token;
	while((nexp == -1 || nion == -1) && std::getline(fi, line)){
		if (regex_match(line, "#.*shot.*")){
			if(!tk.next(fi, token)){
				std::cerr << "Invalid line for shot\n";
				goto RETURN_FAIL;
			}
			shot = std::stoi(token);
			continue;
		}
		if (regex_match(line, "#.*nion.*")){
			if(!tk.next(fi, token)){
				std::cerr << "Invalid line for nion\n";
				goto RETURN_FAIL;
			}
			nion = std::stoul(token);
			continue;
		}
		if (regex_match(line, "#.*nexp.*")){
			if(!tk.next(fi, token)){
				std::cerr << "Invalid line for nexp\n";
				goto RETURN_FAIL;
			}
			nexp = std::stoul(token);
			continue;
		}
	}

	bool end = (nexp == -1 || nion == -1);
	if (nexp == -1) std::cerr << "Error No specification of nexp\n";
	if (nion == -1) std::cerr << "Error No specification of nion\n";
	if (end) exit(-1);

	Plasma plasma(shot, nexp, nion);

	while(std::getline(fi, line)){
		if (regex_match(line, "#.*name.*")){
			std::getline(fi, line);
			std::stringstream ss(line);
			for (size_t i = 0; i < plasma.nion; i++){
				std::string name;
				ss >> name;
				species_identifiers.push_back(name);
			}
			continue;
		}
		if (regex_match(line, "#.*masse.*")){
			if(!tk.next(fi, token)){
				std::cerr << "Invalid line for masse\n";
				goto RETURN_FAIL;
			}
			plasma.masse = std::stod(token);
			continue;
		}
		if (regex_match(line, "#.*\\s+ze\\s*")){
			if(!tk.next(fi, token)){
				std::cerr << "Invalid line for ze\n";
				goto RETURN_FAIL;
			}
			plasma.ze = std::stod(token);
			continue;
		}
		if (regex_match(line, "#.*\\s+mass\\s*.*")){
			for (size_t i = 0; i < plasma.nion; i++){
				if(!tk.next(fi, token)){
					std::cerr << "Invalid line for mass\n";
					goto RETURN_FAIL;
				}
				plasma.mass[i] = std::stod(token);
			}
			continue;
		}
		if (regex_match(line, "#.*\\s+z(?:$|\\s+.*)")){
			for (size_t i = 0; i < plasma.nion; i++){
				if(!tk.next(fi, token)){
					std::cerr << "Invalid line for z\n";
					goto RETURN_FAIL;
				}
				plasma.z[i] = std::stod(token);
			}
			continue;
		}
		if (regex_match(line, "#.*\\s+polflux\\s*.*")){
			for (size_t i = 0; i < plasma.nexp; i++){
				if(!(tk.next(fi, token) && tk.next(fi, token))){ // index value
					std::cerr << "Invalid line for polflux\n";
					goto RETURN_FAIL;
				}
				// For some reason the polflux sign here is different than the 
				// sign in the respective G-EQDSK file
				plasma.polflux[i] = (negative_psi ? -1.0 : 1.0) * std::stod(token); 
			}
			continue;
		}
		if (regex_match(line, "#.*\\s+ne\\s*.*")){
			for (size_t i = 0; i < plasma.nexp; i++){
				if(!(tk.next(fi, token) && tk.next(fi, token))){ // index value
					std::cerr << "Invalid line for ne\n";
					goto RETURN_FAIL;
				}
				plasma.ne[i] = std::stod(token); 
			}
			continue;
		}
		if (regex_match(line, "#.*\\s+ni\\s*.*")){
			for (size_t i = 0; i < plasma.nexp; i++){
				tk.next(fi, token); // index
				for (size_t ion = 0; ion < plasma.nion; ion++){
					if(!tk.next(fi, token)){
						std::cerr << "Invalid line for ni\n";
						goto RETURN_FAIL;
					}
					plasma.ni(ion, i) = std::stod(token);
				}
			}
			continue;
		}
		if (regex_match(line, "#.*\\s+te\\s*.*")){
			for (size_t i = 0; i < plasma.nexp; i++){
				if(!(tk.next(fi, token) && tk.next(fi, token))){ // index value
					std::cerr << "Invalid line for te\n";
					goto RETURN_FAIL;
				}
				plasma.te[i] = std::stod(token); 
			}
			continue;
		}
		if (regex_match(line, "#.*\\s+ti\\s*.*")){
			for (size_t i = 0; i < plasma.nexp; i++){
				tk.next(fi, token); // index
				for (size_t ion = 0; ion < plasma.nion; ion++){
					if(!tk.next(fi, token)){
						std::cerr << "Invalid line for ti\n";
						goto RETURN_FAIL;
					}
					plasma.ti(ion, i) = std::stod(token);
				}
			}
			continue;
		}
	}

	return plasma;
}

#endif // FOCUS_INCLUDE_FORMATS_INPUT_GACODE_HPP
