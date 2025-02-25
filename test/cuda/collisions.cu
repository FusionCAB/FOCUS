#include <iostream>
#include <fstream>
#include <stdlib.h>

#include "formats/matrix.hpp"
#include "formats/geqdsk.hpp"
#include "formats/input_gacode.hpp"
#include "lorentz.hpp"
#include "magnetic_field.hpp"
#include "types/equilibrium.hpp"
#include "types/vector.hpp"
#include "types/particle.hpp"
#include "types/plasma.hpp"
#include "odeint/integrator.hpp"
#include "odeint/stepper/rk46_nl.hpp"
#include "cxxopts.hpp"
#include "collisions/focker_plank.hpp"

class ArrayObserver{
	Array<double> &_times;
	Array<State> &_states;
	double _a, _v0, _Omega;
	bool cart;
	size_t index = 0;
	size_t Nout;
public:
	__host__ __device__
	ArrayObserver(Array<double> &times, Array<State> &states, double a, double v0, double Omega, size_t Nout, bool cart_coord = false): _times(times), _states(states), _a(a), _v0(v0), _Omega(Omega), cart(cart_coord), Nout(Nout) {}
	
	__host__ __device__
	void operator()(State v, double t){
		#ifdef __CUDA_ARCH__
		size_t i = (threadIdx.x + blockDim.x * blockIdx.x) * Nout + index;
		#else
		size_t i = index;
		#endif

		_times[i] = t / _Omega;
		if (cart)
			_states[i] = {v[0] * cos(v[1]) * _a, v[0] * sin(v[1]) * _a, v[2] * _a, (v[3] * cos(v[1]) - v[4] * sin(v[1])) * _v0, (v[3] * sin(v[1]) + v[3] * cos(v[1])) * _v0, v[5] * _v0};
		else
			_states[i] = {v[0]  * _a, v[1] , v[2] * _a, v[3] * _v0, v[4] * _v0, v[5] * _v0};
		index++;
	}
};

template<typename system_type, typename state_type, typename scalar_type, typename CollisionOperator_t>
class CollisionStepper{
	const size_t collisions_nstep;
	size_t steps = 0;
	RK46NL<system_type, state_type, scalar_type> orbit_stepper;
	CollisionOperator_t& collision_operator;
public:
	__host__ __device__
	CollisionStepper(size_t nstep, CollisionOperator_t& collisions): collisions_nstep(nstep), collision_operator(collisions) {}

	__host__ __device__	
	void do_step(system_type sys, state_type& x, scalar_type t, scalar_type dt){
		orbit_stepper.do_step(sys, x, t, dt);
		if (++steps == collisions_nstep){
			collision_operator.euler_step(x, t, dt * collisions_nstep);
			steps = 0;
		}
	}
};

// Integration Kernel
__global__
void k_integrate(MagneticFieldMatrix B_matrix, Equilibrium eq, State x0, double t0, double dt, size_t Nsteps, Array<double> times, Array<State> states, size_t Nout, size_t nskip, Plasma beta, Particle test_part, double eta, double kappa, PhiloxCuRand philox){
	MagneticFieldFromMatrix B(B_matrix, eq.bcentr);

	double q_over_m =  9.58e7; // C/kg proton
	double Omega = q_over_m * eq.bcentr; // cyclotron frequency
	double v0 = 1.84142e7; // m/s (3.54 MeV of a proton)
	double a = eq.rdim; // m
	double gam = v0 / (a * Omega); // dimensionless factor

	typedef Lorentz<NullForce, MagneticFieldFromMatrix, NullVectorField> System;
	System sys(gam, test_part, B, d_null_vector_field, d_null_force);
	
	// Collisions operator
	FockerPlank<PhiloxCuRand, MagneticFieldFromMatrix> collisions(beta, test_part, B, eta, kappa, philox);

	// Stepper
	CollisionStepper<System, State, double, FockerPlank<PhiloxCuRand, MagneticFieldFromMatrix>> stepper(200, collisions);

	State x = x0;
	ArrayObserver obs(times, states, a, v0, Omega, Nout, true);

	integrate(stepper, sys, x, t0, dt, Nsteps, obs, nskip);
}

void integrate_in_device(MagneticFieldMatrix& B_matrix, Equilibrium& eq, State x0, double t0, double dt, size_t Nsteps, std::string ofname, size_t nskip, Plasma plasma, size_t nparts = 1){
	size_t Nout = size_t(Nsteps / (nskip + 1));
	Array<State> h_states(nparts * Nout);
	Array<State> d_states;
	d_states.construct_in_host_for_device(h_states);

	Array<double> h_times(nparts * Nout);
	Array<double> d_times;
	d_times.construct_in_host_for_device(h_times);

	double eta = 2.27418e-12;
	double kappa = 0.0238557;

	// Particles
	Particle alpha(4.001506, 1);

	PhiloxCuRand philox(nparts);
	kernel_init_philox_rand<<<1, nparts>>>(philox, 1);

	Plasma d_plasma(0, 0, 0);
	d_plasma.construct_in_host_for_device(plasma);

	k_integrate<<<1, nparts>>>(B_matrix, eq, x0, t0, dt, Nsteps, d_times, d_states, Nout, nskip, d_plasma, alpha, eta, kappa, philox);

	h_states.copy_to_host_from_device(d_states);
	h_times.copy_to_host_from_device(d_times);

	for (size_t par = 0; par < nparts; par++){
		std::ofstream fo(ofname + std::to_string(par));

		for(size_t i =0; i < Nout; i++){
			fo << h_times[par * Nout + i] << ' ' << h_states[par * Nout + i] << '\n';
		}

		fo.close();
	}
}

void integrate_in_host(MagneticFieldMatrix& B_matrix, Equilibrium& eq, State x0, double t0, double dt, size_t Nsteps, std::string ofname, size_t nskip, Plasma& plasma){
	
	MagneticFieldFromMatrix B(B_matrix, eq.bcentr);

	double q_over_m =  9.58e7; // C/kg proton
	double Omega = q_over_m * eq.bcentr; // cyclotron frequency
	double v0 = 1.84142e7; // m/s (3.54 MeV of a proton)
	double a = eq.rdim; // m
	double gam = v0 / (a * Omega); // dimensionless factor

	typedef Lorentz<NullForce, MagneticFieldFromMatrix, NullVectorField> System;
	Particle alpha(4.001506, 1);
	System sys(gam, alpha, B, null_vector_field, null_force);
	
	double eta = 2.27418e-12;
	double kappa = 0.0238557;

	// Particles

	NormalRand ran(1);

	// Collisions operator
	FockerPlank<NormalRand, MagneticFieldFromMatrix> collisions(plasma, alpha, B, eta, kappa, ran);

	// Stepper
	CollisionStepper<System, State, double, FockerPlank<NormalRand, MagneticFieldFromMatrix>> stepper(200, collisions);

	State x = x0;
	size_t Nout = size_t(Nsteps / (nskip + 1));
	Array<State> states(Nout);
	Array<double> times(Nout);

	ArrayObserver obs(times, states, a, v0, Omega, Nout, true);
	integrate(stepper, sys, x, t0, dt, Nsteps, obs, nskip);

	std::ofstream fo(ofname);

	for(size_t i =0; i < states.size(); i++){
		fo << times[i] << ' ' << states[i] << '\n';
	}

	fo.close();
}

void output_b(MagneticFieldMatrix& B_matrix, Equilibrium& eq){
	dump("Br.dat", B_matrix.Br, false);
	dump("Bt.dat", B_matrix.Bt, false);
	dump("Bz.dat", B_matrix.Bz, false);


	std::cout << B_matrix.r_min * eq.rdim << ' ' << B_matrix.r_max * eq.rdim << ' ' << B_matrix.z_min * eq.rdim << ' ' << B_matrix.z_max * eq.rdim << '\n';
	std::ofstream fobdry("bdry.dat");

	for (size_t i = 0; i < eq.nbdry; i++)
		fobdry << eq.rbdry[i] << ' ' << eq.zbdry[i] << '\n';
	fobdry.close();

	std::ofstream folim("lim.dat");
	for (size_t i = 0; i < eq.nlim; i++)
		folim << eq.rlim[i] << ' ' << eq.zlim[i] << '\n';
	folim.close();
}

int main(int argc, char* argv[]){
	cxxopts::options options("collisions", "Test collisions in CUDA");

	options.add_options()
		("geqdsk_input_file", "", cxxopts::value<std::string>())
		("input_gacode_file", "", cxxopts::value<std::string>())
		("host_file", "", cxxopts::value<std::string>()->default_value("col_host.dat"))
		("device_file", "", cxxopts::value<std::string>()->default_value("col_device.dat"))
		("b,magnetic-field", "Output magnetic field data")
		("h,help", "Show this help message");

	options.positional_help("<G-EQDSK input file> <input.gacode file>  [<Host collisions out file> [<Device collisions out file>]]");
	options.parse_positional({"geqdsk_input_file", "input_gacode_file", "host_file", "device_file"});

	try{
		auto result = options.parse(argc, argv);
	
		if (result.count("help")){
			std::cout << options.help() << std::endl;
			return 0;
		}

		Equilibrium eq = read_geqdsk(result["geqdsk_input_file"].as<std::string>());
		MagneticFieldMatrix B_matrix(eq, 26, 600);

		if (result.count("magnetic-field")){
			output_b(B_matrix, eq);
			return 0;
		}

		State x0 = {2.2 / eq.rdim, 0, 0, 0.0, 0.01, 0.3};
		double t0 = 0;
		double dt = 0.0001;
		size_t N 	= 30000000;
		size_t nskip 	= 999;
		double logl_prefactor = 18.4527;

		std::vector<std::string> species_identifiers;
		Plasma plasma = read_input_gacode(result["input_gacode_file"].as<std::string>(), species_identifiers);
		plasma.logl_prefactor = logl_prefactor;
		
		integrate_in_host(B_matrix, eq, x0, t0, dt, N, result["host_file"].as<std::string>(), nskip, plasma);
		integrate_in_device(B_matrix, eq, x0, t0, dt, N, result["device_file"].as<std::string>(), nskip, plasma, 3);

		return 0;
	}
	catch(cxxopts::option_error const& e){
		std::cerr << e.what() << std::endl;
		return 1;
	}

	return 0;
}